# ASUS Pro WS W680-ACE: setup

A workstation board with DDR5 **ECC** support, used here as the storage and GPU host (backup): an Intel 14th-gen CPU with its iGPU shared into LXCs, a discrete GPU passed to a VM, two HBAs, and NVMe pools. The BIOS settings below are what that combination needs; the reasons are the useful part. Related: [gpu-passthrough.md](gpu-passthrough.md), [igpu-lxc.md](igpu-lxc.md), [ecc.md](ecc.md).

## Hardware notes

| | |
|---|---|
| CPU | Intel Core i7-14700 (8P + 12E, 28 threads), UHD 770 iGPU |
| RAM | DDR5-4800 ECC UDIMMs (e.g. 2× 48 GB in Controller0-DIMM1 + Controller1-DIMM1) |
| NICs | 2× Intel I226-LM 2.5 GbE: one per VLAN (management / server) |
| PCIe | two PCIe 5.0 ×16 slots that run **×8/×8** when both are used; two PCIe 3.0 slots that are **electrically ×4** |
| M.2 | M.2_1 from the CPU (PCIe 4.0 ×4, the lowest latency: guest storage); M.2_2 / M.2_3 from the chipset (fine for passthrough to a NAS VM) |
| SlimSAS | can run in PCIe mode for a U.2 NVMe |

**A typical layout:** the GPU in the first PCIe 5.0 slot (×8 is no loss for inference); IT-mode SAS HBAs in the two ×4 slots (an ×8 HBA links at ×4 there, ~2 GB/s, plenty for HDDs); U.2 NVMe on M.2_1 and SlimSAS; the chipset M.2 slots for the NAS VM's special-vdev NVMe.

**Microcode:** Raptor Lake needs `0x12F` or newer for Intel's degradation fix: `grep -m1 microcode /proc/cpuinfo`. Update the BIOS first.

## BIOS settings

| Screen | Setting | Value | Why |
|---|---|---|---|
| CPU Power Management | CPU C-states | Enabled | idle power on a 24/7 machine |
| CPU Power Management | **Package C State Limit** | **C6** | C8/C10 caused wake failures of the passed-through GPU; C0/C1 wastes power |
| System Agent | VT-d | Enabled | IOMMU for passthrough |
| System Agent | **Control IOMMU Pre-boot Behavior** | **Enable IOMMU during boot** | without it VT-d doesn't fully take effect |
| Graphics Configuration | Primary Display | CPU Graphics | the iGPU stays primary; the dGPU stays free for the VM |
| Graphics Configuration | **iGPU Multi-Monitor** | **Enabled** | keeps the iGPU alive with a dGPU present: without it `/dev/dri` doesn't appear for the LXCs |
| Graphics Configuration | **RC6 (Render Standby)** | **Disabled** | the iGPU slept between frames at 5 fps and failed to wake (`Failed to sync surface` in Frigate) |
| Graphics Configuration | **DVMT Pre-Allocated** | **512 MB** | 256 MB gave `Can't allocate a surface` with five camera streams + OpenVINO |
| VMD Configuration | **Enable VMD controller** | **Disabled** | VMD (Intel RST) hides the drives from the OS; ZFS needs them directly (AHCI) |
| PCH Storage | **Aggressive LPM Support** | **Disabled** | link power management caused ZFS errors and drive timeouts |
| APM Configuration | **Restore AC Power Loss** | **Power On** | "Last State" stays off after a clean UPS shutdown ([architecture/power.md](../architecture/power.md)) |
| APM Configuration | **ErP Ready** | **Disabled** | ErP cuts USB power in standby, which drops the UPS's USB link and with it NUT |
| PCI Subsystem | Above 4G Decoding | Enabled | GPU passthrough with a BAR over 4 GB |
| PCI Subsystem | Re-Size BAR | Enabled (but ROM-Bar and Primary GPU off in the VM) | |
| Onboard Devices | HD Audio, Wi-Fi & BT | Disabled | unused |

**Optional power tuning** (idle ~40–60 W with guests running can drop to ~25–35 W): PL1 75 W, PL2 110–120 W, Tau 28–56 s, a mild undervolt (adaptive offset −0.05 to −0.075 V, start conservative), max turbo 4.8 GHz P-cores / 3.6 GHz E-cores.

## Checks after a BIOS update or hardware change

```bash
grep -m1 microcode /proc/cpuinfo                                  # ≥ 0x12F
grep . /sys/devices/system/edac/mc/mc*/{ce,ue}_count             # ECC: MC0 + MC1 (ie31200_edac), 0 errors
dmidecode -t memory | grep -E 'Total Width|Data Width'           # 72 / 64 bit = ECC modules
for d in $(lspci -D | awk '/VGA|NVMe|SAS/ {print $1}'); do echo "== $d"; lspci -vv -s $d | grep -E 'LnkCap:|LnkSta:'; done
grep . /sys/class/scsi_host/host*/version_fw                      # HBAs: 20.00.07.00 (P20)
```

A GPU links at low speed when idle (e.g. 2.5 GT/s): confirm the full speed under load from inside the VM. U.2 drives should show 16 GT/s ×4.

## Host notes

- **Bootloader:** systemd-boot with a ZFS root: change `/etc/kernel/cmdline`, then `proxmox-boot-tool refresh` (not `update-grub`).
- **Kernel cmdline:** `root=ZFS=rpool/ROOT/pve-1 boot=zfs quiet iommu=pt video=efifb:off`.
- **CPU governor:** `powersave` (`/etc/tmpfiles.d/cpu-governor.conf`: `w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - powersave`).
- **NVMe pool maintenance** with autotrim off: put the jobs in **`/etc/cron.d/<file>`**, not `crontab -e`. Lines there have a user field (`0 3 * * * root /usr/sbin/zpool trim <pool>`), which only `/etc/crontab` and `/etc/cron.d/` understand; in a user crontab, cron runs `root …` as a command, mails `root: not found`, and the job never runs.
- **Kernels:** start with Proxmox's default. Pin an older one (`proxmox-boot-tool kernel pin <ver>`) only if GPU passthrough performance or DMAR faults show up on a newer one.
