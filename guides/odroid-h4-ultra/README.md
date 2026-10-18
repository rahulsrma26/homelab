# ODROID-H4 Ultra: setup

Hardkernel's low-power x86 board (Intel i3-N305), used here as an always-on Proxmox server (primary). This guide covers what matters before and after installing an OS on it: limits of the hardware, which BIOS image to flash, updating and recovering the BIOS, and the settings to change. Every BIOS menu and option as it appears on screen: [bios-options.md](bios-options.md).

Sources: Hardkernel's ODROID-H4 wiki and the BIOS 1.12 release notes.

## Hardware

| | |
|---|---|
| CPU | Intel Core i3-N305 (Alder Lake-N), 8 cores / 8 threads, 1.8 GHz base, 3.8 GHz single-core / 3.0 GHz all-core |
| Power | 15 W nominal; BIOS 1.12 defaults PL1 18 W / PL2 35 W |
| iGPU | Intel UHD, 32 EUs; AV1/HEVC decode |
| RAM | 1× DDR5 SO-DIMM, **single channel**, runs at 4800 MT/s. Hardkernel says 48 GB; **64 GB modules work** |
| In-band ECC | supported (BIOS 1.02+), costs 1/32 of RAM: the only ECC an N305 can do |
| NVMe | 1× M.2 2280, PCIe 3.0 ×4, split ×4 / 2×2 / 4×1 **by flashing the matching BIOS image** |
| SATA | 4× SATA III via an ASM1064 on **one PCIe 3.0 lane** (H4+/Ultra); no port multipliers |
| Network | 2× 2.5 GbE (Intel I226-V), Wake-on-LAN |
| Video | 1× HDMI 2.0 + 2× DisplayPort, three 4K60 displays at once |
| Power input | DC 5.5/2.1 mm, 11–20 V. 15 V/4 A without 3.5" HDDs; 19 V/7 A with more than one |
| Cooling | passive heatsink; optional 92 mm 12 V 4-pin PWM fan (max 15 mm thick for Hardkernel's cases) |
| Other | fTPM 2.0, dual BIOS (jumper-selected), eMMC socket, 120 × 120 mm |

## Limits worth knowing

- **No hot-plug.** Swapping SATA, NVMe or eMMC with power on can damage the board and the drive.
- **SATA bandwidth is shared:** all four ports go through one PCIe 3.0 lane, about 985 MB/s together (≈230 MB/s per drive with all four busy; one SSD alone reaches ~500 MB/s). A 4-SSD pool tops out around 1 GB/s.
- **M.2 length:** the onboard slot takes **2280** only. Enterprise drives (e.g. Samsung PM983) are 22110 and need the 2×2 adapter or a case with a 110 mm post.
- **2×2:** each NVMe gets PCIe 3.0 ×2 (~2 GB/s), plenty for a boot/guest mirror. One NVMe on the normal image gets ×4 (~3.9 GB/s).
- **The SO-DIMM socket is rated for only 25 insertions.** To use one board as another's spare, move the NVMe drives, not the RAM. A module that won't boot: clean its contacts with a pencil eraser first.
- **RTC battery** hangs on a small 2-pin connector and can be knocked off: tape it down. Without it the settings are lost, the next boot is slow (memory training, up to ~3 min), and the board powers on by itself whenever power is applied.
- **First boot** after assembly, or after losing the settings, takes up to 3 minutes (RAM training): not a fault.
- **systemd-boot hangs with some NVMe drives** (seen with two PM983s): at every start systemd-boot writes and flushes `loader/random-seed` on the boot partition, and the firmware's NVMe driver times out (`random-seed.c: Failed to flush random seed file: Time out`, then `Error opening root path: Time out`). Linux's own NVMe driver is fine. Fix: boot Proxmox with GRUB ([`scripts/proxmox-grub-boot`](../../scripts/proxmox-grub-boot/)). Deleting `loader/random-seed` also works, until the next `proxmox-boot-tool init`.
- **Wake-on-LAN + a 2.5 GbE switch:** with WoL enabled, `poweroff` can act like a reboot (Hardkernel's note). A server that must stay off after a UPS shutdown should have WoL off.

## Which BIOS image

The BIOS package contains three images, one per M.2 lane split. Flashing the wrong one leaves a second NVMe undetected, or limits a single drive to ×2.

| Image | M.2 slot as | Script | For |
|---|---|---|---|
| `ADLN-H4_B<ver>.bin` | 1× PCIe 3.0 ×4 | `fb.nsh` | one NVMe |
| `ADLN-H4_B<ver>-2X2.bin` | 2× PCIe 3.0 ×2 | `fb2.nsh` | two NVMe on the M.2 2×2 card (a server's mirror) |
| `ADLN-H4_B<ver>-4X1_netcard.bin` | 4× ×1 | `fbnet.nsh` | Hardkernel's Net Card (4 extra NICs) |

The 2×2 and Net Card builds of 1.12 **default PCIe ASPM to Auto**; **the normal build leaves it Disabled**, so set it by hand there (below). A board kept as a spare for a 2×2 server must have the 2×2 image flashed before it can see both drives.

Downloads: `dn.odroid.com/ODROID-H4/bios/` (check the `.sha256`).

## Updating

1. A **USB 2.0 stick in a USB 2.0 port** (USB 3.0 sticks and ports cause most failed flashes), FAT32.
2. Check the zip (`sha256sum -c <zip>.sha256` on Linux, `shasum -a 256 -c <zip>.sha256` on macOS), unzip, and copy the **contents** (EFI folder, `Fpt.efi`, `.bin`s, `.nsh`s) to the stick's root.
3. The board on a **UPS**: a power cut mid-flash bricks that BIOS chip.
4. BIOS (**DEL** at boot) → Save & Exit → Boot Override → the stick → EFI shell.
5. `fs0:` (or `fs1:`: the one listed as *Removable HardDisk*; check with `ls`; **never `blk0:`**), then the script for your image (`fb2` for 2×2, `fb` for the normal one). Don't power off while it runs; wait for "FPT Operation Successful".
6. **Cold boot:** pull the DC plug, wait a few seconds, plug in, power on.
7. Flashing **resets every setting**: photograph the changed pages first, then redo the settings below.

**F7** at boot gives a one-time boot menu.

## Recovery (dual BIOS)

Two BIOS chips; a jumper picks one (no jumper = the first).

1. Power off, put the jumper on the **good** BIOS, boot it with the flash stick inserted.
2. EFI shell: `fs0:` → `fpt -disableme`.
3. Move the jumper to the **failed** BIOS position (while running).
4. Flash it: `Fpt.efi -f ADLN-H4_B<ver>-2X2.bin` (or the image you use). From Windows: `FPTW64.exe -f …` in an admin prompt.
5. On "FPT Operation Successful": pull the power, **wait ~5 minutes**, power on.

If both chips fail: reflash the SPI chip on the bottom of the PCB with a programmer (see Hardkernel's H3 restore guide).

## Settings

| Setting | Where | Always-on server | Desktop / media PC | Why |
|---|---|---|---|---|
| **In-Band ECC** | Chipset → System Agent → Memory Configuration → In-Band ECC Support | **On**, mode 2 (protect all) | optional | the only ECC the N305 has; costs 1/32 of RAM |
| **PCIe ASPM** | Chipset → PCH-IO → PCI Express Configuration → Root Port 3/4 (NICs), 7 (SATA), 9–12 (M.2) | **Auto** | **Auto** (set by hand on the normal image) | ~2.5 W less at idle. Hardkernel leaves it off because *some NVMe drives get unstable*: afterwards watch `journalctl -k` for NVMe resets or PCIe AER errors and `zpool status` for errors; if any, set ports 9–12 back to Disabled |
| **Wake on LAN** | Chipset → PCH-IO → Wake on LAN Enable (+ `ethtool -s <nic> wol g` in the OS) | **Off** | only if something should wake it | with WoL on behind a 2.5 GbE switch, `poweroff` can act like a reboot, which breaks a UPS shutdown |
| **Power on after power loss** | Chipset → PCH-IO → State After G3 | **S0** (power on) | S5 (stay off) | servers must boot when power returns |
| USB power under S5 | Chipset → PCH-IO → USB port power under S5 | Off | only if a USB device must stay powered while off | lower off-power |
| Suspend | Advanced → ACPI Settings → ACPI Sleep State | S3 (default) | S3 (needed to wake from a USB dongle) | — |
| Power limits | Advanced → CPU – Power Management Control → Config TDP Configurations | default: Nominal, PL1 18000 / PL2 35000 mW | Nominal; **Level1** (PL1 9 W) to run cooler and quieter | higher limits only help with a fan; without one the CPU throttles near Tj |
| Fan curve | Advanced → Hardware Monitor → Smart Fan Function | automatic, quiet curve | automatic, quiet curve | the curve follows the CPU package temperature; PWM 0–255 (Hardkernel's fan: ~1000 rpm at 127, ~2000 at 255) |
| TCO watchdog | Chipset → PCH-IO → Enable TCO Timer | off on Proxmox unless set up deliberately (`watchdog` + `wdat_wdt`) | off | reboots a hung box; Proxmox has its own watchdog-mux |
| RTC alarm | Advanced → RTC Alarm | off | off | scheduled power-on, if ever needed |
| Boot logo | Boot → Enable Boot Logo | off | off | faster boot |
| Serial console | Advanced → SPCR | off (on when debugging headless) | off | UART0 on the expansion header |

**Power limits in 1.12:** Advanced → CPU – Power Management Control shows *Platform PL1 Enable*, *Platform PL2 Enable* and *Power Limit 4 Override* (all off by default), and the *Config TDP Configurations* page: Boot Mode *Nominal* (ratio 18, PL1 18000 / PL2 35000 mW) or *Level1* (ratio 10, PL1 9 W). The cTDP values are real milliwatts.

**PL4 quirk** (older BIOSes, and the PL4 override): the value shown is 3× the real watts (30000 = 10 W, 48000 = 16 W, 0 = unlimited ≈ 16 W). Hardkernel's all-core measurements with a fan: 21000 → 2.0 GHz / 10 W; 30000 → 2.6 GHz / 13.8 W; 48000 or 0 → 3.3 GHz / ~21 W, 70 °C. Idle power doesn't change.

**After any BIOS update:** re-check IB-ECC, ASPM, power-on-after-loss and WoL first.

## BIOS versions (what changed that matters)

| Version | Date | Change |
|---|---|---|
| 1.02 | 2024-05 | 2×2 NVMe image; **In-Band ECC** |
| 1.03 | 2024-05 | "Wake on LAN Enable" actually works |
| 1.04 | 2024-07 | WoL setting fixed; **USB port power under S5** |
| 1.05 | 2024-09 | PKfail Secure Boot fix (Secure Boot menu hidden until Security → Secure Boot is enabled) |
| 1.06 | 2024-11 | **RTC alarm**, boot-logo option, setup prompt 5 s |
| 1.07 | 2024-12 | **TCO watchdog** |
| 1.08 | 2025-01 | hybrid graphics (M.2 dGPU + iGPU) |
| 1.09 | 2026-01 | microcode 0x10 → **0x1E**; HDMI/DP priority (VBT Select); Secure Boot broke |
| 1.10 | 2026-01 | RTC alarm restored |
| 1.11 | 2026-01 | Secure Boot works again; CSM disabled |
| 1.12 | 2026-04 | display fixes (some 4K monitors); **TDP options**, PL1 18 W / PL2 35 W by default (was 15 W) |

## Power draw (Hardkernel's measurements)

| State | Power |
|---|---|
| headless idle, BIOS defaults (ASPM off) | ~5.3 W |
| headless idle, **ASPM Auto** | **~2.8 W** (2.4 W without Ethernet) |
| desktop idle | ~5.9 W |
| 4K video playback | ~15 W |
| CPU + GPU stress | ~19–22 W (34+ W unlimited, with a fan) |
| suspend to RAM | ~0.9–1.4 W |
| off | ~0.2 W |

ASPM is the biggest lever for a 24/7 board: ~2.5 W, ~22 kWh a year. With enterprise NVMe drives (power-loss protection), the M.2 links may stay at ASPM disabled even with Auto, and keep the CPU out of its deepest idle states: the cost of PLP drives, not something software can fix.

## PCIe root ports (BIOS numbering)

| Root port | Device |
|---|---|
| 1, 2 | USB 3.0 ports |
| 3, 4 | the two I226-V NICs |
| 7 | ASM1064 SATA controller |
| 9–12 | the M.2 slot (lanes as split by the image) |
| 5, 6, 8 | unused |

## Expansion header (24-pin, 2.54 mm, 3.3 V logic)

| Signal | Pin | Pin | Signal |
|---|---|---|---|
| GND | 1 | 2 | 5V_RUN (only while running, max 1 A) |
| USB2 P7 D+ | 3 | 4 | 3.3V_RUN (only while running, max 700 mA) |
| USB2 P7 D− | 5 | 6 | GND |
| USB2 P5 D+ | 7 | 8 | UART0 RXD |
| USB2 P5 D− | 9 | 10 | UART0 TXD |
| GND | 11 | 12 | UART0 CTS# |
| I2C1 SCL | 13 | 14 | UART0 RTS# |
| I2C1 SDA | 15 | 16 | GND |
| **PWR_BTN#** (short to GND momentarily) | 17 | 18 | I2C0 SCL |
| GND | 19 | 20 | I2C0 SDA |
| USB2 P6 D+ | 21 | 22 | **HDMI_CEC** |
| USB2 P6 D− | 23 | 24 | **V5P0A** (always on, even when off; max 600 mA) |

- **External power button:** pin 17 + GND (pin 19), momentary switch only. Hardkernel's illuminated button: LED + to pin 4 (lit while on); pin 14 would keep it lit when off.
- **Serial console:** UART0 on pins 8/10 (cross RX/TX to a USB-UART), enabled in BIOS → Advanced → SPCR; works for the BIOS screen too.
- **HDMI-CEC** (e.g. to let a TV switch the board on): a Pulse-Eight *NUC* HDMI-CEC adapter, its cable rewired to this header. Hardkernel's published wiring:

  | Signal | H4 pin | Adapter pin |
  |---|---|---|
  | GND | 1, 6, 11, 16 or 19 | 4 |
  | 5V Standby | 2 | 9 |
  | USB D+ | 21 | 6 |
  | Power button | 17 | 7 |
  | USB D− | 23 | 8 |
  | 5V Detect | 24 | 5 |
  | CEC | 22 | 10 |

  **Check two rows before soldering:** by the header map, pin 2 is 5V_RUN (off when the board is off) and pin 24 is V5P0A (always on). A standby supply on pin 2 would leave the adapter unpowered while the board is off, so it couldn't switch it on, and "detect" on the always-on pin would always report the PC as on: these two look swapped. Compare with Pulse-Eight's pinout and measure both pins with the board off before connecting.

## Fan, LEDs

- **Fan:** 12 V 4-pin PWM, controlled by the BIOS curve. Software control from Linux needs the out-of-tree `it87` driver (`pwm2`), so the BIOS curve is the simpler choice.
- **LEDs:** red = DC power; blue left = running (off in suspend); blue right = main rails up; amber = SATA activity; green = NVMe activity.
- **RAM check without a display:** with a compatible module, a short press of the power button in the BIOS turns the board off at once; with no or an incompatible module it needs a 5-second hold.
