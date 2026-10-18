# ECC memory: enable, verify, alert

Two kinds of ECC in this lab, set up and checked differently:

| Kind | Example | How | Kernel driver |
|---|---|---|---|
| **Hardware ECC** | a W680 board + Intel 14th-gen + DDR5 ECC UDIMMs | ECC modules, checked by the CPU's memory controller | `ie31200_edac` (loads by itself) |
| **In-band ECC (IB-ECC)** | Intel Alder Lake-N (N100, N305), e.g. the ODROID-H4 | normal non-ECC RAM; the memory controller keeps the ECC data in a reserved slice of it. Must be enabled in the BIOS | `igen6_edac` (loads by itself when IB-ECC is on) |

Neither notifies anyone by itself: the last step, an alert, is what makes it useful.

## 1. Enable

- **Hardware ECC:** nothing to enable; it works when the CPU, board and modules support it.
- **IB-ECC:** in the BIOS, e.g. on the ODROID-H4 Ultra: Chipset → System Agent → Memory Configuration → In-Band ECC Support, mode "protect all" ([odroid-h4-ultra/](odroid-h4-ultra/)). It costs 1/32 of the RAM and some bandwidth: worth it on a machine that stores data.

## 2. rasdaemon

Keeps a history of memory errors across reboots (the kernel's counters reset at boot):

```bash
apt install -y rasdaemon
systemctl enable --now rasdaemon
```

## 3. Verify

**Hardware ECC:**

```bash
dmidecode -t memory | grep -i 'error correction'   # "Single-bit ECC"
lsmod | grep edac                                   # ie31200_edac
dmesg | grep -i edac                                # e.g. "EDAC MC0: Giving out device to module ie31200_edac controller IE31200" (and MC1)
```

**IB-ECC:**

```bash
dmesg | grep -i edac
# EDAC MC0: Giving out device to module igen6_edac controller Intel_client_SoC MC#0 ... (INTERRUPT)
# ← the proof: igen6_edac only registers MC0 when IB-ECC is on
grep -H . /sys/devices/system/edac/mc/mc0/{mc_name,size_mb,ce_count,ue_count}
grep MemTotal /proc/meminfo     # a little below the installed RAM: IB-ECC reserves its slice
```

- `dmidecode` shows **no** ECC with IB-ECC: expected. It describes the module, which is a normal one.
- `igen6_edac` missing: `modprobe igen6_edac` and add it to `/etc/modules` (normally not needed).
- **No error injection** on Proxmox kernels: they're built without EDAC debug support (`/sys/kernel/debug/edac/` is empty). The MC0 registration is the proof.

**Both:**

```bash
awk '{s+=$1} END {print "corrected:", s}'   /sys/devices/system/edac/mc/mc*/ce_count
awk '{s+=$1} END {print "uncorrected:", s}' /sys/devices/system/edac/mc/mc*/ue_count
ras-mc-ctl --status       # "drivers are loaded"
ras-mc-ctl --summary      # history across reboots
```

`ras-mc-ctl --summary` says **"no such table: mc_event"** for a few minutes after rasdaemon starts. That's normal: it first waits 30 s for each CXL trace event, which never appears without CXL hardware, and only then creates its database. It repeats on every boot; the kernel counters and `dmesg` cover that window. "No CXL errors" in the summary is expected too.

## 4. Alert

Node exporter's EDAC collector (through Alloy) exports `node_edac_correctable_errors_total` and `node_edac_uncorrectable_errors_total`. Alert on **any** uncorrectable error (critical) and on a **rising** correctable count (warning): see `MemoryUncorrectableError` and `MemoryCorrectableErrors` in [`services/monitoring`](../services/monitoring/config/prometheus/). A slowly rising correctable count is the early warning of a failing module.
