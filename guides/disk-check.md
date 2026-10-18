# Checking a disk before trusting it

What to check on every new (or newly used, or second-hand) disk before it holds data, and what to record, so later SMART readings have a baseline. Takes 10–30 minutes per batch, plus the long self-test for HDDs.

```bash
apt install -y smartmontools nvme-cli lm-sensors
ls -l /dev/disk/by-id/ | grep -v part     # the stable names you'll build pools from
```

## 1. Identity, link and firmware

```bash
smartctl -i /dev/sdX          # model, serial, firmware, capacity, sector sizes, "SATA Version … (current: 6.0 Gb/s)"
smartctl -i /dev/nvme0        # NVMe: model, firmware, namespaces
dmesg | grep -iE 'ata[0-9]+: SATA link|link reset|hard resetting'   # the negotiated speed; resets point at cables or ports
lspci -vv -s <nvme-pci-id> | grep -E 'LnkCap:|LnkSta:'               # NVMe: e.g. 8GT/s x4 (Gen3 ×4) as expected for the slot
```

- A SATA SSD at 3.0 Gb/s instead of 6.0, or an NVMe at fewer lanes than the slot gives, means a cable, a port, a riser or a BIOS lane split (see [odroid-h4-ultra/](odroid-h4-ultra/) for one board's M.2 options).
- Update the firmware first if the vendor lists a fix that matters.

## 2. SMART: health and the counters that matter

```bash
smartctl -H -A -l error /dev/sdX     # SATA/SAS
smartctl -H -A /dev/nvme0            # NVMe (or: nvme smart-log /dev/nvme0)
```

| Look at | SATA attribute | NVMe field | Should be |
|---|---|---|---|
| overall | `PASSED` | `critical_warning` | PASSED / 0 |
| reallocated sectors | 5 | — | 0 |
| pending sectors | 197 | — | 0 |
| uncorrectable | 198 | `media_errors` | 0 |
| **interface CRC errors** | 199 | — | 0: anything else is a cable or backplane problem, not the disk |
| SATA downshifts | 183 (some vendors) | — | 0 |
| wear | 177 / 233 / vendor ("wearout", "media wearout indicator", 100 = new) | `percentage_used` (0 = new) | as new, or what the seller claimed |
| power-loss protection | some enterprise SSDs report a capacitor test (e.g. 175) | — | passed / 100 |
| power-on hours, data written | 9, 241 / vendor | `power_on_hours`, `data_units_written` | record them |
| error log | `smartctl -l error` | `nvme error-log` | empty (NVMe error-log entries that smartd marks as ignored are common and harmless) |

Second-hand enterprise disks are fine with tens of thousands of hours if the error counters are 0 and the wear is low.

## 3. Self-tests

```bash
smartctl -t short /dev/sdX            # ~2 min
smartctl -t long  /dev/sdX            # HDDs: ~1 hour per TB or more (≈2 days for 22 TB)
smartctl -l selftest /dev/sdX | head -8
```

Some NVMe drives don't support self-tests at all; their SMART counters and the load test below are the check.

**New HDDs** can get a full write pass before they hold anything (destroys all data on the disk; days on large drives):

```bash
badblocks -b 4096 -wsv /dev/sdX       # then a long self-test again, and compare the counters
```

## 4. Load and temperature, in the closed case

Temperatures on an open bench say nothing about the closed case. With the lid on and the fans as they'll run (e.g. a fixed or automatic curve), load all the disks at once for a few minutes and watch the peaks:

```bash
# writes to a scratch dataset with compression and caching off, so the disks really work
zfs create -o compression=off -o primarycache=metadata <pool>/burnin
dd if=/dev/urandom of=/<pool>/burnin/big bs=1M count=20000 status=progress &
# reads straight from each disk at the same time
for d in /dev/disk/by-id/<disk-a> /dev/disk/by-id/<disk-b>; do dd if=$d of=/dev/null bs=1M count=20000 iflag=direct status=none & done
watch -n 5 'for d in /dev/sd? /dev/nvme?; do printf "%s " $d; smartctl -A $d | grep -iE "^194|Temperature:" | head -1; done; sensors | grep -i package'
# afterwards
wait; zfs destroy <pool>/burnin
```

- **NVMe:** stay well below the drive's warning limit (`smartctl -c` / `nvme id-ctrl` show WCTEMP/CCTEMP; e.g. 86 °C warning on enterprise drives); `Warning/Critical Comp. Temperature Time` must stay 0, and no thermal-throttle messages in `dmesg`.
- **SATA SSDs / HDDs:** HDDs ideally under ~45 °C; set smartd's limits accordingly (NVMe run hotter, so they get their own limits: [proxmox-host.md](proxmox-host.md), step 6).
- After the test: media errors still 0, no new kernel warnings.

## 5. Record a baseline

Per disk, write down: model, serial (in your private notes), firmware, where it sits (slot/port), its pool, and the first readings (hours, data written, wear, the error counters, the peak temperature under load). A slowly climbing CRC, reallocated or correctable-error count is only visible against such a baseline. From then on, smartd watches it and alerts ([proxmox-host.md](proxmox-host.md), step 6), and the monitoring stack alerts on wear and failed health ([architecture/monitoring.md](../architecture/monitoring.md)).
