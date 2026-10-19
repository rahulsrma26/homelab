# Network

UniFi router and switches; managed switches carry the VLANs. Each host has two 2.5 GbE NICs.

## VLANs


| VLAN           | Who                                                                                  | Can reach                                                                                       |
| -------------- | ------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| **management** | Proxmox hosts, Tang boards, admin guests (Tailscale, Uptime Kuma, Authelia), the NAS | everything                                                                                      |
| **server**     | all service guests                                                                   | the internet; **not** management                                                                |
| **home**       | phones, laptops, TVs                                                                 | server ports 3000–9999 except monitoring's Prometheus (9090) and Loki (3100), plus the reverse proxy (80/443) and the file server (445) |
| **iot**        | smart devices                                                                        | Home Assistant's specific ports only; not each other                                            |
| **camera**     | cameras, their recorder                                                              | nothing (the recorder alone may reach the internet for remote viewing)                          |
| **guest**      | guest Wi-Fi                                                                          | the internet only                                                                               |
| **dmz**        | the public VM                                                                        | the internet, and only the specific internal ports its public services proxy to (e.g. Immich's) |


Narrow exceptions are written per rule, never as "server → management": e.g. TrueNAS → primary's SSH for replication, Home Assistant → the hosts' NUT ports.

Monitoring's raw Prometheus and Loki APIs accept Alloy traffic from management/server guests and the public VM's specific DMZ exception. The home VLAN is blocked from these APIs; browsers use Grafana. Apply the monitoring-specific deny rules before the broader home-to-server port allowance.

## Hosts: one bond, one VLAN-aware bridge

Both NICs of a host form an **active-backup bond** under a single **VLAN-aware bridge** (`vmbr0`); the switch ports are trunks.

| Piece | What |
|---|---|
| `bond0` | both NICs, `active-backup`: one carries the traffic, the other takes over if its link fails. No switch-side configuration, so the two cables can even go to two different switches |
| `vmbr0` | VLAN-aware bridge on the bond, allowed VLANs limited to what the host's guests use (`bridge-vids`) |
| `vmbr0.<management>` | **the host's only address**, on the management VLAN. The host has no address in any other VLAN |
| guests | `bridge=vmbr0,tag=<vlan>`: the host sets each guest's VLAN, a guest can't choose its own |
| switch ports | trunks carrying those VLANs, **native VLAN none**, so untagged traffic goes nowhere |

- **Why not LACP:** it speeds up many parallel connections, not a single transfer (still one link's 2.5 Gbit/s); both cables must go to the same switch; it needs matching switch config, a mismatch locks the host out; and it gets in the way of Wake-on-LAN while a host is off. Active-backup gives the redundancy without those.
- **Separation is by VLAN, not by cable:** management and guest traffic share the links, each in its own tagged VLAN, kept apart by the router's firewall rules.
- A guest that must reach two VLANs (monitoring, the admin terminal) gets two NICs on the same bridge, one per tag, so it needs no firewall exception.

## Addresses

Written as `192.168.<vlan>.<name>`; real subnets aren't documented here.

- **One number space for management and server.** A last octet is used once, in whichever of the two VLANs it sits, so moving a guest between them changes only the VLAN, never the number.
- **Shared services** have a low range of their own, **independent of the host** they run on: a guest that moves to another host keeps its address. Movable guests live here.
- **Each Proxmox host has its own range** for itself and the guests tied to it (e.g. primary's file server, which serves primary's disks).
- **Static below the DHCP pool**, set in each guest's own config (labber sets it); every fixed address also gets a name in UniFi.
- **Guest IDs follow addresses:** CT ID = 1000 + last octet, so the ID tells you the address.



## DNS and names

- **Resolver:** Technitium, a main instance on primary and secondaries on the Tang boards, which keep names resolving while primary is down.
- **Internal names:** `<app>.home.<domain>`. A local wildcard record points `*.home.<domain>` at the reverse proxy; the bare `home.<domain>` (the start page) has its own record.
- **Certificates:** one wildcard certificate for `*.home.<domain>`, issued by Let's Encrypt through a Cloudflare DNS-01 challenge. Internal names never need to be reachable from the internet.
- **A public TXT record** for `home` keeps the public `*` wildcard from covering `*.home`: otherwise browsers that look up HTTPS records (Chromium) find the public wildcard first and slow down.



## Reverse proxy

**Traefik** on primary serves every internal name, with routes in one file (`dynamic/routes.yml`, see [`services/traefik`](../services/traefik/)) that Traefik reloads by itself.

- **Browsers use names, services use addresses.** A link a person opens is `https://<app>.home.<domain>`. One service talking to another uses the container name (same compose project) or the guest's address, not the public name: otherwise every call goes through DNS and the proxy, both of which can be down when the two services are fine.
- **Middlewares** (`dynamic/common.yml`): security headers on every route; a variant that allows same-origin framing for apps that embed their own pages; the dashboard behind a password.
- Status checks (Homepage, Uptime Kuma) use addresses too, so they stay correct when the proxy is down.



## Remote access

**No inbound ports.** Remote access is Tailscale:

- **A Tailscale LXC on each host**, on the management VLAN, advertising the subnets. On primary it sits on unencrypted storage, so it is up even when the disks haven't unlocked.
- **Names work remotely** through split DNS: `home.<domain>` is resolved by the home DNS, so `<app>.home.<domain>` opens the same way at home and on mobile data.
- **Family devices** get only the service routes (Tailscale ACLs); admin devices reach everything.
- **Fallback:** UniFi's own remote access, which also works for an emergency disk unlock.



## Public access

Only a few services are public (e.g. a share-link proxy for Immich). They run on the **public VM** on secondary, behind a **Cloudflare Tunnel** (no open port) and a separate Traefik in `cf` mode ([`services/traefik`](../services/traefik/)):

- **its own VLAN (`dmz`)**, so the router, not only the VM's own firewall, limits what it can reach: the internet (for the tunnel) and the few internal ports it proxies to;
- the Docker socket only through a read-only socket proxy;
- only containers labelled for exposure are routed;
- forwarded headers trusted from Docker's networks only, so apps see the visitor's real address;
- JSON access logs with the visitor's address, shipped to monitoring;
- the VM's Proxmox firewall allows the same again, as a second fence: inbound only SSH from the admin network, outbound only the tunnel and the proxied ports.

Primary's Traefik is never reachable from the internet.
