# Tailscale LXC (remote access)

One small unprivileged LXC per Proxmox host, advertising the management and server subnets over Tailscale. It's the remote path to everything, including the **emergency disk unlock**, so on an encrypted host it lives on **unencrypted** storage and starts even when the disks stay locked ([architecture/network.md](../architecture/network.md#remote-access)).

## Create

1 core, 512 MB RAM, 512 MB swap, 8 GB disk, a NIC in each VLAN:

```bash
pveam update && pveam download local debian-13-standard_<ver>_amd64.tar.zst
pct create <ID> local:vztmpl/debian-13-standard_<ver>_amd64.tar.zst \
  --hostname <name> \
  --cores 1 --memory 512 --swap 512 \
  --rootfs local-zfs:8,mountoptions=noatime\;discard \
  --net0 name=eth0,bridge=vmbr0,tag=<mgmt-vid>,firewall=1,ip=<mgmt-ip>/24,gw=<mgmt-gw> \
  --net1 name=eth1,bridge=vmbr0,tag=<server-vid>,firewall=1,ip=<server-ip>/24 \
  --unprivileged 1 --onboot 1 --startup order=1
pct set <ID> --features keyctl=1,nesting=1
```

**TUN device:** an unprivileged LXC has no `/dev/net/tun`, which Tailscale needs. Add to `/etc/pve/lxc/<ID>.conf`:

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

It only lets programs inside create their own virtual network interfaces; it gives no access to the host's network.

## Install

```bash
pct start <ID> && pct enter <ID>
apt update && apt upgrade -y && apt install -y curl

# forwarding, for subnet routing and an exit node
printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' > /etc/sysctl.d/99-tailscale.conf
sysctl -p /etc/sysctl.d/99-tailscale.conf

curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
tailscale set --advertise-routes=192.168.management.0/24,192.168.server.0/24 --advertise-exit-node
```

## In the Tailscale admin console

1. **Approve** the device and **enable its subnet routes** (and the exit node, if wanted).
2. **Disable key expiry** for it: node keys expire after 180 days by default, and an expired key on the remote-access node locks you out, or makes an old backup of it useless after a restore. The trade-off: a stolen node key stays valid until you remove the node, so do that at once if the LXC or a backup of it is ever exposed, and keep its ACLs tight (this node needs to *offer* routes, not reach other nodes).
3. **Split DNS:** add the home domain (e.g. `home.<domain>`) with the home DNS server as its resolver, so `<app>.home.<domain>` works on the road.
4. **ACLs:** family devices to the service routes only; admin devices everywhere.

## Backups

The LXC barely changes. One PBS backup, marked **Protected** so pruning never removes it, is enough; with key expiry off, restoring an old copy needs no re-login.
