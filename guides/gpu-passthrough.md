# GPU passthrough (VFIO) on Proxmox

Passing a discrete NVIDIA GPU to a VM, while the CPU's iGPU stays with the host for sharing into LXCs. The host-side steps are also in [proxmox-host.md](proxmox-host.md) (steps 9–10); this guide adds the reasons, the VM settings and what's specific to each GPU generation.

## BIOS

- **VT-d** (IOMMU) on; where offered, **"Enable IOMMU during boot"** (Control IOMMU Pre-boot Behavior).
- **Above 4G Decoding** on; **VMD** off.
- **Primary display = CPU graphics** (iGPU), so the host never initialises the dGPU.
- Deep CPU package C-states can break waking a passed-through GPU: **Package C State Limit = C6** fixed it on a W680 board (C8/C10 caused wake failures).

## Host

**Kernel command line** (`/etc/kernel/cmdline` with systemd-boot, `GRUB_CMDLINE_LINUX_DEFAULT` with GRUB; then `proxmox-boot-tool refresh` or `update-grub`):

```
quiet iommu=pt
```

| Parameter | Why |
|---|---|
| `iommu=pt` | passthrough mode: the host skips DMA translation for its own devices (faster). Intel's IOMMU is on by default since kernel 6.8, so `intel_iommu=on` isn't needed |
| `nofb nomodeset video=vesafb:off,efifb:off` | only if the host still claims the dGPU (`lspci -nnk` shows a driver other than `vfio-pci`) |
| `pcie_acs_override=downstream` | **last resort**, if the GPU shares an IOMMU group with other devices: it breaks the isolation the IOMMU provides. Try another PCIe slot first |

**Modules and bindings:**

```bash
printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' >> /etc/modules     # load early, before snd_hda_intel grabs the GPU's audio
cat > /etc/modprobe.d/blacklist.conf <<'EOF'
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist nvidia_drm
blacklist nvidia_modeset
EOF
lspci -nn | grep -i nvidia                                         # the GPU's and its audio function's IDs
echo 'options vfio-pci ids=10de:<gpu>,10de:<audio>' > /etc/modprobe.d/vfio.conf
echo 'options kvm ignore_msrs=1 report_ignored_msrs=0' > /etc/modprobe.d/kvm.conf
update-initramfs -u -k all && reboot
```

**Never blacklist `i915`:** it's the iGPU driver the LXCs share.

## Verify

```bash
dmesg | grep -e DMAR -e IOMMU        # "DMAR: IOMMU enabled"
dmesg | grep remapping               # "DMAR-IR: Enabled IRQ remapping in x2apic mode": without it passthrough fails
lsmod | grep vfio                    # vfio, vfio_iommu_type1, vfio_pci
lspci -nnk | grep -A3 -i nvidia      # "Kernel driver in use: vfio-pci"
pvesh get /nodes/$(hostname)/hardware/pci --pci-class-blacklist ""   # the GPU + its audio alone in their IOMMU group
```

## The VM

| Setting | Value | Why |
|---|---|---|
| Machine | q35 | PCIe passthrough |
| BIOS | OVMF (UEFI) | |
| CPU type | host | passes the CPU's flags; also fixes OVMF's MMIO sizing for large VRAM, so no `X-PciMmio64Mb` workaround |
| Memory | ballooning off (`balloon: 0`) | a passed-through device needs all guest memory pinned |
| PCI device | **All Functions** + **PCI-Express** | the GPU and its audio together |

## Per GPU generation

| | RTX 50 series (Blackwell, e.g. RTX 5060 Ti) | RTX Ada workstation (e.g. RTX 2000E Ada) |
|---|---|---|
| `disable_idle_d3=1` | **needed**: `options vfio-pci ids=… disable_idle_d3=1`, or the GPU falls into D3cold and disappears between VM starts | not known to be needed; add only if the GPU becomes inaccessible |
| VM: ROM-Bar / Primary GPU | **both off** | try on first |
| Guest driver | the **open** kernel module (e.g. `nvidia-driver-*-open`): required for Blackwell | the **open** kernel module too (supported since Turing; NVIDIA's default) |

## Guest driver (Debian 13)

Debian's own `nvidia-driver` is an older branch (550, CUDA ≤ 12.4): recent CUDA 13 images and inference servers need a newer driver. NVIDIA's Debian repository has current branches; pin one so updates stay within it:

```bash
curl -fsSLO https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb && sudo apt update
sudo apt install linux-headers-$(uname -r) nvidia-driver-pinning-<branch>   # e.g. 595
sudo apt install nvidia-driver-cuda nvidia-kernel-open-dkms                  # headless; DKMS rebuilds it on kernel updates
sudo reboot
nvidia-smi
```

Coming from Debian's driver: purge its `nvidia*`, `libnvidia*` and `libcuda*` packages first (keep `libnvidia-container*` and `nvidia-container-toolkit*`). For Docker: install `nvidia-container-toolkit`, run `sudo nvidia-ctk runtime configure --runtime=docker`, restart Docker, check with `docker run --rm --gpus all ubuntu:24.04 nvidia-smi -L`.

**After a driver change, recreate GPU containers** (`docker compose up -d --force-recreate`): a container created under an older driver can keep the toolkit's CUDA forward-compatibility library, which the newer driver rejects ("unsupported display driver / cuda driver combination"); apps such as llama.cpp then silently fall back to the CPU.

## Troubleshooting

| Symptom | Check |
|---|---|
| GPU stuck in D3cold / gone after a VM stop | `disable_idle_d3=1`; PCIe ASPM disabled in the BIOS (PCH and SA PCI Express); `dmesg \| grep vfio` for D3cold timeouts; last resort `pcie_aspm=off` |
| VM won't start, "group X" errors | the GPU shares an IOMMU group: another slot, then (last resort) `pcie_acs_override=downstream` |
| IOMMU not detected | VT-d and "Enable IOMMU during boot" in the BIOS; with systemd-boot, the cmdline is `/etc/kernel/cmdline` + `proxmox-boot-tool refresh` |
| no `/dev/dri/renderD128` on the host (iGPU) | BIOS: iGPU Multi-Monitor on, Primary Display = CPU graphics; `i915` not blacklisted |
| iGPU transcoding fails after idle | RC6 (render standby) put the iGPU to sleep: BIOS → Graphics Configuration → RC6 = Disabled |
