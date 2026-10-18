# Disk encryption

All guest and data storage is **ZFS-native encrypted** (AES-256-GCM). Hosts unlock themselves at boot by asking a **Tang** server on the network (through **Clevis**), so a power cut needs no one at the keyboard, while a stolen host stays locked.

## Design

1. **Every host is the same Clevis client**; two Tang servers serve the keys.
2. **Shamir 1-of-2:** either Tang alone can unlock any host, so losing one is a non-event.
3. **Tang off Proxmox:** tang-a and tang-b are bare-metal single-board computers on the management VLAN, independent of any hypervisor. Both boot in under a minute after an outage, before any host asks.
4. **Never placed with the hosts:** someone who takes a host *and* a Tang (to their own network) could unlock it. Where they are is deliberately not written down here.

```
   tang-a ───┐   Clevis SSS 1-of-2   ┌─── tang-b
             └──────────┬────────────┘
          ┌─────────────┼─────────────┐
       primary      secondary       backup
```

## On each host

- **One random 32-byte raw key per host**, shared by its encrypted datasets: e.g. `rpool/encrypted` (guest disks) and `<datapool>/encrypted` (data). New datasets go below these and inherit the key.
- **Three copies of the key:**
  1. wrapped by both Tangs (`clevis encrypt sss`), on the host: the normal path;
  2. passphrase-encrypted, on the host: the emergency path when no Tang answers. The file sits on the unencrypted root, so the passphrase must be long enough to resist offline guessing;
  3. the raw key in the password manager: the only copy that survives losing both boot disks.
- `keylocation=prompt` is required: the Clevis pipe only works with it.
- **Proxmox storages:** `enc-nvme` / `enc-sata` on the encrypted datasets; the unencrypted `local-zfs` holds only the Tailscale LXC.

## Boot

```
1. Proxmox boots from the unencrypted root; pools import
2. zfs-unlock.service: clevis decrypt (asks the Tangs, retrying) → zfs load-key → zfs mount -a
3. pve-guests starts the guests
     unlocked     → everything starts
     not unlocked → encrypted guests fail; the Tailscale LXC (unencrypted) still starts,
                    so the emergency unlock can be run remotely
```

`zfs-unlock.service` is `WantedBy=pve-guests.service`, not `RequiredBy`: with `RequiredBy`, a failed unlock would stop *every* guest from starting, the Tailscale one included.

## Threat model

| Scenario | Result |
|---|---|
| reboot or power cut | unlocks from a Tang by itself |
| a host stolen | off-network, no Tang → stays locked (if the emergency passphrase is strong) |
| a disk pulled | encrypted, no key → unreadable |
| one Tang down | the other serves every host |
| both Tangs down + reboot | manual unlock: console, or remotely via Tailscale + passphrase |
| a host *and* a Tang stolen together | **not safe**: they can complete the exchange (hence never in the same place) |
| both boot disks of a host die | recoverable **only** from the raw key in the password manager |

## Tang servers

- Keys in `/var/lib/tang/*.jwk`, backed up in the password manager (the file name is the key's thumbprint).
- Each Tang's address is stored inside every client's Clevis file: changing it means re-binding every host.
- Uptime Kuma checks each Tang's `/adv` endpoint.
