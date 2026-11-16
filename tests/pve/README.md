# Real-Proxmox tests

`labber-host` and `services/monitoring/utils/push-tokens.sh` against a real Proxmox host: a real firewall (`pve-firewall`), real CTs, ZFS snapshots and sanoid. They run in a **throwaway Proxmox VM ("pve-ci") nested in a test Proxmox host**, never on a host anything else uses: `run.sh` rolls pve-ci back to its snapshot `clean`, starts it, copies this working tree in, runs `*.bats` there as root, and stops it. Whatever a test breaks inside is undone by the next run.

```bash
PVE_TEST_HOST=root@<test host> PVE_CI_VMID=<id> PVE_CI_ADDR=<pve-ci's address> PVE_CI_NET=<test bridge /24 prefix> \
    tests/pve/run.sh              # ~15 min; KEEP=1 leaves it running; --refresh updates its snapshot
```

| File | What it checks |
|---|---|
| `labber-host.bats` | snap refused without `firewall=1` or with the host's firewall off (nothing stopped); snap closes for real (the CT's port stops answering), stops the services, pauses sanoid, snapshots the CT disk and an owned dataset; rollback undoes what was written since and stays closed; open answers again; rollback refused under a newer (sanoid) snapshot |
| `push-tokens.bats` | the script on a terminal with hidden prompts (`answer.py` types each answer only once its prompt is shown): the host and a real guest (Docker, a running container, labber's remembered URLs gone) push with their group's token afterwards; only Alloy changed on the guest (no apt run, the container not restarted); a guest with its own monitoring skipped; one on an old labber refused, nothing left behind; the host's old config kept; a second run with Enter changes nothing |

pve-ci: Proxmox with a ZFS pool `cipool`, an internal bridge `vmbr1` (`<prefix>.1/24`, NAT out) for the test CTs, a Debian 13 CT template, `sanoid`, `bats`, `git`, `jq`; the guest agent (to reach it if a test cuts SSH). It's reached through the test host (`ssh -J`).
