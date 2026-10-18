# A new LXC or VM

Creating a guest on a Proxmox host and getting it ready for services. Inside the guest, [`labber setup`](../labber/) does the rest (packages, key-only SSH, security updates, Docker, monitoring, a static address).

## Conventions

- **Address and ID:** pick the address by [architecture/network.md](../architecture/network.md): a shared number if the guest could move to another host, the host's own range if it's tied to that host. **CT/VM ID = 1000 + the last octet** (`.11` → 1011).
- **Bridge and VLAN:** `vmbr0` with the guest's VLAN as a tag: the server VLAN for services, management for admin tools, the DMZ for the public VM; two NICs (one per tag) when it needs two VLANs.
- **Storage:** the encrypted storage (`enc-nvme`); only the Tailscale LXC goes on unencrypted `local-zfs`.
- **Data:** bind mounts from the host's datasets, with `backup=0` so PBS backs up only the guest's own disk ([architecture/storage.md](../architecture/storage.md)).
- **Start order:** Tailscale `order=1`, the reverse proxy `order=2`, the rest default.
- **LXCs run as root** (key-only SSH): the unprivileged mapping is the isolation. **VMs get an admin user with sudo**, and root login off.

## LXC

```bash
pveam update
pveam available | grep debian-13                  # the current template name
pveam download local debian-13-standard_<ver>_amd64.tar.zst

pct create <ID> local:vztmpl/debian-13-standard_<ver>_amd64.tar.zst \
  --hostname <name> \
  --cores <n> --memory <mb> --swap 512 \
  --rootfs enc-nvme:<gb>,mountoptions=noatime\;discard \
  --net0 name=eth0,bridge=vmbr0,tag=<server-vid>,firewall=1,ip=dhcp \
  --unprivileged 1 --onboot 1
# a second NIC, for a guest in two VLANs:    --net1 name=eth1,bridge=vmbr0,tag=<mgmt-vid>,firewall=1,ip=dhcp
# Docker inside:                              pct set <ID> --features nesting=1
# a data mount:                               pct set <ID> -mp0 /<pool>/<dataset>,mp=/mnt/<name>,backup=0
# the iGPU (e.g. Immich, Jellyfin):           pct set <ID> -dev0 /dev/dri/renderD128,gid=<render-gid-in-guest>

pct start <ID>
pct enter <ID>
```

Then, inside, as root:

```bash
apt update && apt install -y curl
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/labber/labber) setup
```

It ends by printing any `pct set` commands to run on the host (nesting, the hostname, the static address).

- **Editing the config file by hand:** give each interface an `hwaddr=…`; without one, the web UI throws a TypeError.
- **Proxmox's firewall for the guest** needs both the NIC's `firewall=1` **and** the guest's own firewall switched on (Firewall → Options → Firewall: Yes, `enable: 1` in its `.fw` file), and the datacenter firewall on. With only `firewall=1`, the rules are written but none apply.

## VM

Only where an LXC won't do ([architecture/principles.md](../architecture/principles.md)): a full OS of its own, a GPU or disks passed through.

- **Machine q35, BIOS OVMF**, disk on `enc-nvme` with discard, VirtIO SCSI single, CPU type `host`, the **QEMU guest agent** enabled (clean shutdowns, and the host sees its address).
- Install Debian 13 (minimal), then from the console as root: `apt install -y curl` and the same `labber setup` line. In a VM it also creates the admin user, turns root login off, installs `qemu-guest-agent`, and can set a static address with an automatic rollback if the connection is lost.
- GPU passthrough: [gpu-passthrough.md](gpu-passthrough.md).

## After

- `labber <service> install` for each service ([`services/`](../services/)).
- The PBS job picks the guest up by itself (selection "All").
- Add it to the reverse proxy's routes and the start page if it has a web UI.
