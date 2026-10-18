# A public VM behind a Cloudflare Tunnel

The one machine reachable from the internet: a small Debian VM running **cloudflared** (an outbound-only tunnel, no open port) and **Traefik in `cf` mode**, which routes each public hostname to a container on the VM. Everything else in the lab stays private. Design: [architecture/network.md](../architecture/network.md#public-access); the Traefik side: [`services/traefik`](../services/traefik/).

```
visitor → Cloudflare (TLS, WAF) → tunnel (outbound from the VM) → cloudflared → Traefik :80 (127.0.0.1) → container
```

It holds nothing irreplaceable and is rebuilt from the repo, so it goes on the host **without important data**, in its own **DMZ VLAN**.

## 1. The VM

| Setting | Value |
|---|---|
| Machine / BIOS | default (i440fx / SeaBIOS): no passthrough |
| CPU | host, 2 cores; 2 GB RAM; a small disk on encrypted storage |
| NIC | the **dmz** VLAN; **Firewall** ticked (`firewall=1`) |
| OS | Debian 13, minimal: an admin user with sudo, root login off |

Inside: a static address (`/etc/network/interfaces`), then `labber setup` ([new-guest.md](new-guest.md)): key-only SSH, unattended security updates, Docker with log rotation, Alloy.

## 2. Two firewalls

**The router** (the DMZ VLAN, [architecture/network.md](../architecture/network.md)): out to the internet; in to exactly the internal ports the public services proxy to (e.g. Immich's API); nothing else, no management, no other server guests.

**The VM's Proxmox firewall**, enforced by the hypervisor, so it can't be switched off from inside the VM. **Three switches, all needed:**

1. the NIC's **Firewall** tick (`firewall=1`): only *routes* the traffic through the firewall;
2. **the VM's own firewall:** VM → Firewall → Options → **Firewall: Yes** (`enable: 1`), off by default;
3. **the datacenter firewall** on that host (Datacenter → Firewall → Options). On an unclustered host it's a per-host setting; turning it on applies its default input policy, so first allow the management network to the host's SSH and web UI, or you lock yourself out.

With only 1, the rules are written but **none apply**: the VM can reach the whole LAN on any port. This was found once on a running public VM.

`/etc/pve/firewall/<VMID>.fw`:

```
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: DROP

[RULES]
IN  ACCEPT -source <admin-network> -p tcp -dport 22 -log nolog          # SSH from the admin network only
OUT ACCEPT -dest <gateway> -p udp -dport 53 -log nolog                  # DNS
OUT ACCEPT -dest <gateway> -p tcp -dport 53 -log nolog                  # DNS, large answers
OUT ACCEPT -p tcp -dport 443 -log nolog                                 # HTTPS: apt, image pulls, cloudflared's API
OUT ACCEPT -p tcp -dport 7844 -log nolog                                # the tunnel (HTTP/2)
OUT ACCEPT -p udp -dport 7844 -log nolog                                # the tunnel (QUIC)
OUT ACCEPT -p udp -dport 123 -log nolog                                 # NTP
OUT ACCEPT -dest <immich> -p tcp -dport 2283 -log nolog                 # the one internal app it proxies
OUT ACCEPT -dest <monitoring> -p tcp -dport 9090,3100 -log nolog        # Alloy → Prometheus, Loki
OUT DROP   -dest 192.168.0.0/16 -log nolog                              # nothing else internal
```

- Inbound: SSH only. cloudflared connects **out**, so the tunnel needs no inbound rule.
- Outbound: default drop; a compromised VM can't reach other internal hosts or exfiltrate on arbitrary ports.
- Forgetting 7844 takes the tunnel down the moment the firewall applies; forgetting TCP 53 breaks large DNS answers.

**apt over HTTPS:** with outbound port 80 closed, Debian's default `http://` sources fail. Switch them to `https://deb.debian.org` and `https://security.debian.org` (in `/etc/apt/sources.list` or `/etc/apt/sources.list.d/debian.sources`).

**Check it's really enforced** (on the VM):

```bash
curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://example.com   # 000: port 80 out is blocked
dig +time=2 +tries=1 @192.0.2.53 example.com                      # times out: DNS only to the gateway
nc -zvw3 <another-internal-host> 22                                 # times out
sudo apt update                                                     # works
```

Plus a public link opened over mobile data (the tunnel works).

## 3. The tunnel

**Create it from the CLI, never in the Cloudflare dashboard.** A dashboard-created tunnel is *remotely managed*: Cloudflare pushes its own ingress config over your local `config.yml`, which makes wildcard routing impossible. Ignore the dashboard's later "Migrate" prompt for the same reason.

```bash
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update && sudo apt install -y cloudflared
cloudflared tunnel login                   # ~/.cloudflared/cert.pem
cloudflared tunnel create <name>           # ~/.cloudflared/<tunnel-id>.json, prints the id
```

`/etc/cloudflared/config.yml`: everything to Traefik, which routes by hostname:

```yaml
tunnel: <tunnel-id>
credentials-file: /home/<user>/.cloudflared/<tunnel-id>.json
ingress:
  - hostname: "*.<domain>"
    service: http://localhost:80
  - service: http_status:404
```

**DNS:** one wildcard CNAME `*` → `<tunnel-id>.cfargotunnel.com`, proxied. Cloudflare's Universal SSL covers `*.<domain>` (one level deep only, so names like `*.home.<domain>` are unaffected).

**Service:** don't use `cloudflared service install` (it creates a token-based, remotely managed service). Write the unit yourself:

```ini
# /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel client
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
TimeoutStartSec=15
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run <name>
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now cloudflared
sudo journalctl -u cloudflared -n 50 | grep 'config='      # the ingress must list *.<domain>, not only http_status:404
```

The tunnel credentials (`cert.pem`, `<tunnel-id>.json`) are secrets: anyone with them can serve your domain. Keep a copy in the password manager, and only there.

## 4. Traefik and the apps

`labber traefik install`, answering **`cf`** for the mode, then each public service (e.g. `labber immich-public-proxy install`). What `cf` mode does ([`services/traefik`](../services/traefik/)):

- Traefik binds **only `127.0.0.1:80`**; containers use `expose`, never `ports`, so nothing else listens.
- The Docker socket only through a **read-only socket proxy** (`POST=0`), never mounted into Traefik.
- Only containers labelled for exposure (`homelab.exposure`) are routed.
- Forwarded headers are trusted from Docker's networks only, so apps see `https` and the visitor's real address (`CF-Connecting-IP`).
- A JSON access log with the visitor's address, collected by Alloy.

**Container rules:** run as non-root where possible (`user: 1000:1000`), `cap_drop: [ALL]` plus only what's needed, no host mounts beyond the app's own data, and never the Docker socket.

## 5. SSH and fail2ban

`labber setup` already makes SSH key-only with root login off. Add `AllowUsers <user>` in `sshd_config`, and fail2ban for SSH. Debian 13 has no `/var/log/auth.log` without rsyslog, so the jail reads the journal:

```ini
# /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
backend = systemd
```

`fail2ban-client status sshd` shows it; `fail2ban-client set sshd unbanip <ip>` unbans.

## 6. Cloudflare settings

- **WAF** managed rulesets (Cloudflare + OWASP), **Bot Fight Mode**, **rate limiting** on login and API paths.
- **Zero Trust Access** in front of anything that isn't meant for everyone (admin pages): Access → Applications → Self-hosted, identity provider **One-time PIN** (no external IdP), an Allow policy for your e-mail addresses, HTTP-only cookie on, SameSite Lax, browser SSH/RDP off. A share-link proxy meant for anyone with the link stays outside Access.
- **Cache rule:** Cloudflare's cache breaks video seeking (HTTP range requests) and downloads. Bypass the cache for paths that serve them, e.g. URI path *starts with* `/share/video/` **or** *ends with* `/download`; photos can be cached.

## 7. If it's ever compromised

Because of the two firewalls it can't reach the rest of the lab, and it holds no data. Rebuild it: delete the VM, revoke the tunnel (`cloudflared tunnel delete <name>`, then create a new one), rotate the secrets its services used (e.g. the Immich API key the share proxy holds), and redeploy from the repo.
