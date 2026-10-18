# ODROID-H4 Ultra BIOS options and information

Firmware shown: **ADLN-H4 1.12 x64**, AMI Aptio Setup, Intel Core i3-N305.

## Contents

- [Scope and reading notes](#scope-and-reading-notes)
- [Keyboard controls](#keyboard-controls)
- [Main](#main)
 - [BIOS and board information](#bios-and-board-information)
 - [Processor, graphics and memory information](#processor-graphics-and-memory-information)
 - [PCH, SPI flash and controller firmware information](#pch-spi-flash-and-controller-firmware-information)
 - [Main settings](#main-settings)
- [Advanced](#advanced)
 - [CPU Configuration](#cpu-configuration)
 - [Efficient-core Information](#efficient-core-information)
 - [Power & Performance](#power--performance)
 - [CPU - Power Management Control](#cpu---power-management-control)
 - [View/Configure Turbo Options](#viewconfigure-turbo-options)
 - [Turbo Ratio Limit Options](#turbo-ratio-limit-options)
 - [Config TDP Configurations](#config-tdp-configurations)
 - [Custom P-state Table](#custom-p-state-table)
 - [Power Limit 3 Settings](#power-limit-3-settings)
 - [CPU Lock Configuration](#cpu-lock-configuration)
 - [GT - Power Management Control](#gt---power-management-control)
 - [Trusted Computing](#trusted-computing)
 - [ACPI Settings](#acpi-settings)
 - [Runtime Error Logging Settings](#runtime-error-logging-settings)
 - [IT8613 Super IO Configuration](#it8613-super-io-configuration)
 - [Serial Port 1 Configuration](#serial-port-1-configuration)
 - [Hardware Monitor](#hardware-monitor)
 - [Smart Fan Function](#smart-fan-function)
 - [RTC Alarm](#rtc-alarm)
 - [Serial Port Console Redirection](#serial-port-console-redirection)
 - [PCI Subsystem Settings](#pci-subsystem-settings)
 - [USB Configuration](#usb-configuration)
 - [Network Stack Configuration](#network-stack-configuration)
 - [NVMe Configuration](#nvme-configuration)
 - [SDIO Configuration](#sdio-configuration)
 - [Intel Ethernet controller information](#intel-ethernet-controller-information)
 - [Generic NVMe PCIe SSD Configuration Data](#generic-nvme-pcie-ssd-configuration-data)
 - [Driver Health](#driver-health)
- [Chipset](#chipset)
 - [System Agent (SA) Configuration](#system-agent-sa-configuration)
 - [Memory Configuration](#memory-configuration)
 - [Graphics Configuration](#graphics-configuration)
 - [External Gfx Card Primary Display Configuration](#external-gfx-card-primary-display-configuration)
 - [LCD Control](#lcd-control)
 - [Intel(R) Ultrabook Event Support](#intelr-ultrabook-event-support)
 - [PCH-IO Configuration](#pch-io-configuration)
 - [PCI Express Configuration](#pci-express-configuration)
 - [PCI Express Root Ports 3, 4, 7 and 9](#pci-express-root-ports-3-4-7-and-9)
 - [PCIE clocks](#pcie-clocks)
 - [SATA Configuration](#sata-configuration)
 - [SerialIo Configuration](#serialio-configuration)
 - [Serial IO I2C0 Settings](#serial-io-i2c0-settings)
 - [Serial IO Touch Panel Settings](#serial-io-touch-panel-settings)
 - [Serial IO I2C1 Settings](#serial-io-i2c1-settings)
 - [SCS Configuration](#scs-configuration)
- [Security](#security)
 - [Secure Boot](#secure-boot)
 - [Key Management](#key-management)
- [Boot](#boot)
- [Save & Exit](#save--exit)
- [Coverage gaps for a complete firmware reference](#coverage-gaps-for-a-complete-firmware-reference)

## Scope and reading notes

- This is a map of every readable setting, information field, action and submenu entry, as shown on screen (BIOS 1.12, normal ×4 image). It is not a firmware extraction or a guarantee that every conditional BIOS option has been captured.
- **Shown value** means the value on screen during this session. It does not establish the factory default, a recommended setting, or whether a change was saved.
- The third set includes open choice-list popups for selected settings. Captured lists, help-listed choices, numeric ranges, units and special values are distinguished below. Complete lists for every setting and hidden dependent settings are not established by these captures. A single shown value must not be interpreted as the only permitted choice.
- Labels follow the BIOS wording, including capitalization and unusual spellings. Square brackets around values are generally omitted for readability. Numeric units are included only where shown; an unlabelled number is preserved without assigning a unit.
- A **submenu** is a visible navigation entry. Where its contents were not captured, that is stated explicitly. Information and status fields are separated from configurable settings where the screen makes that distinction clear.
- Help and captured choices appear beside their settings or directly below comparison tables in the same menu section. A dash in a help column means no description was captured. Help is paraphrased from the screens; firmware wording, special values and hardware qualifications are preserved.

Screen-transition text was used only when its setting could be identified reliably; unresolved limits are listed at the end.

## Keyboard controls


| Key | BIOS legend |
|---|---|
| Left / Right arrows | Select Screen |
| Up / Down arrows | Select Item |
| Enter | Select |
| + / - | Change Opt. |
| F1 | General Help |
| F2 | Previous Values |
| F3 | Optimized Defaults |
| F4 | Save & Exit |
| Esc | Exit |
| K / M | Scroll UP or Down |

## Main


### BIOS and board information

| Information field | Shown value |
|---|---|
| BIOS Vendor | American Megatrends |
| Core Version | 5.26 |
| Compliancy | UEFI 2.8; PI 1.7 |
| Project Version | ADLN-H4 1.12 x64 |
| Build Date and Time | 04/01/2026 10:05:06 |
| Access Level | Administrator |
| FSP Version | 0C.02.89.30 |
| RC Version | 0C.E0.89.30 |
| FSP Information → Build Date | No value displayed |
| FSP Mode | Dispatch Mode |
| Manufacturer Name | HARDKERNEL |
| Board Name | ODROID-H4 |
| Board Version | 1.0 |
| Setup footer version | 2.22.1289 |
| Setup footer copyright year | 2026 |

The build date is preserved in the firmware's original format rather than converted to an assumed date convention.

### Processor, graphics and memory information

| Information field | Shown value |
|---|---|
| Name | AlderLake ULX |
| Type | Intel(R) Core(TM) i3-N305 |
| Speed | 1800 MHz |
| ID | 0xB06E0 |
| Stepping | A0 |
| Package | Not Implemented Yet |
| Number of Efficient-cores | 8Core(s) / 8Thread(s) |
| Microcode Revision | 1E |
| GT Info | 0x46D0 |
| eDRAM Size | N/A |
| IGFX GOP Version | 21.0.1063 |
| Memory RC Version | 0.0.4.73 |
| Total Memory | 49152 MB |
| Memory Frequency | 4800 MHz |

### PCH, SPI flash and controller firmware information

| Information field | Shown value |
|---|---|
| PCH Name | PCH-N |
| PCH SKU | N Premium SKU |
| PCH Stepping | A0 |
| ChipsetInit Base Revision | 2 |
| ChipsetInit OEM Revision | 0 |
| PCH Package | Not Implemented Yet |
| TXT Capability of Platform/PCH | Unsupported |
| Production Type | Production |
| Dual Output Fast Read support | Supported |
| Read ID/Status Clock Freq | 50 MHz |
| Write and Erase Clock Freq | 50 MHz |
| Fast Read Clock Freq | 50 MHz |
| Fast Read support | Supported |
| Number of Components | 1 Component |
| SPI Component 0 Density | 16 MB |
| EC FW Version | 00.00 |
| eSPI Flash Sharing Mode | G3 |
| EC PECI Mode | Legacy PECI mode |
| ME FW Version | 16.50.5.1303 |
| ME Firmware SKU | Consumer SKU |
| PMC FW Version | 160.50.0.1009 |

### Main settings

| Setting | Shown value | Help / captured choices |
|---|---|---|
| System Language | English | — |
| System Date | Sun 01/01/2023 | — |
| System Time | (the board's clock) | Set the time; use **Tab** to switch between time elements. |


## Advanced

 Visible submenu entries, in screen order:

1. CPU Configuration
2. Power & Performance
3. Trusted Computing
4. ACPI Settings
5. Runtime Error Logging Settings
6. IT8613 Super IO Configuration
7. Hardware Monitor
8. RTC Alarm
9. Serial Port Console Redirection
10. PCI Subsystem Settings
11. USB Configuration
12. Network Stack Configuration
13. NVMe Configuration
14. SDIO Configuration
15. Intel(R) Ethernet Controller I226-V — <this board's MAC>
16. Intel(R) Ethernet Controller I226-V — <this board's MAC>
17. Generic NVMe PCIe SSD Configuration Data
18. Driver Health

### CPU Configuration

Path: `Advanced > CPU Configuration`.

Menu help: CPU configuration parameters.

Submenus: **Efficient-core Information** (captured below) and **Performance-core Information** (entry visible; contents not captured).

| Information field | Shown value |
|---|---|
| ID | 0xB06E0 |
| Brand String | Intel(R) Core(TM) i3-N305 |
| VMX | Supported |
| TXT Crash Code | 0x00000000 |
| TXT SPAD | 0x0000000000000000 |
| Boot Guard Status | 0x00000000 |
| Boot Guard ACM Policy Status | 0x0000000000000000 |
| Boot Guard SACM Information | 0x0000007000000000 |

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| C6DRAM | Enabled | Enables/disables moving DRAM contents to PRM memory when the CPU is in C6. |
| CPU Flex Ratio Override | Disabled | Enables/disables CPU Flex Ratio programming. |
| CPU Flex Ratio Settings | 18 | — |
| Intel (VMX) Virtualization Technology | Enabled | When enabled, a virtual-machine monitor can use the additional hardware capabilities provided by Vanderpool Technology. |
| AVX | Enabled | Help refers to enabling/disabling AVX2 instructions and says this applies to Performance-cores only. This is the BIOS's generic help wording; it does not establish a Performance-core on this i3-N305. |
| Active Efficient-cores | All | Number of E-cores enabled per processor package. Core and E-core counts are considered together; when both are `{0,0}`, Pcode enables all cores. |

#### Efficient-core Information

Path: `Advanced > CPU Configuration > Efficient-core Information`.

| Information field | Shown value |
|---|---|
| L1 Data Cache | 32 KB × 8 |
| L1 Instruction Cache | 64 KB × 8 |
| L2 Cache | 2048 KB × 2 |
| L3 Cache | 6 MB |

### Power & Performance

Path: `Advanced > Power & Performance`.

Menu help: Power and performance options.

| Submenu | Menu help |
|---|---|
| CPU - Power Management Control | CPU power-management control options. |
| GT - Power Management Control | GT power-management control options. |

#### CPU - Power Management Control

Path: `Advanced > Power & Performance > CPU - Power Management Control`.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| Boot performance mode | Turbo Performance | Performance state that the BIOS sets starting from the reset vector. |
| Intel(R) SpeedStep(tm) | Enabled | Allows support for more than two frequency ranges. |
| Race To Halt (RTH) | Enabled | Dynamically increases CPU frequency so the package enters a C-state faster to reduce overall power; controlled through MSR 1FC bit 20. Popup choices Disabled, Enabled. |
| Intel(R) Speed Shift Technology | Enabled | Enables/disables Speed Shift support. Enabling exposes the CPPC v2 interface for hardware-controlled P-states. |
| Per Core P State OS control mode | Enabled | Disabling sets bit 31 to 1 using command 0x06; the highest core request is then used for all other core requests. |
| HwP Autonomous Per Core P State | Enabled | Disabling Autonomous PCPS sets bit 30 to 1 using command 0x11; autonomous operation requests the same value for all cores all the time. Enabling PCPS is described as the default, with bit 30 = 0, command 0x11. |
| HwP Autonomous EPP Grouping | Enabled | Enabled (default: bit 29 = 0, command 0x11) requests the same values for cores with the same EPP. Disabled (bit 29 = 1, command 0x11) does not necessarily request the same values. Popup choices Disabled, Enabled. |
| EPB override over PECI | Disabled | Enables/disables EPB override through PECI. Enabling sends Pcode command 0x2b, subcommand 0x3 = 1, allowing OOB EPB PECI override control. |
| HwP Lock | Enabled | Enables/disables HWP Lock support in the Misc Power Management MSR. |
| HDC Control | Enabled | Configures HDC. Disabled disables it; Enabled allows the OS to enable it if native OS support is available. |
| Turbo Mode | Enabled | — |
| Platform PL1 Enable | Disabled | Enables/disables Platform Power Limit 1 programming. Enabling activates PL1 to limit average processor power over a time window. |
| Platform PL2 Enable | Disabled | Enables/disables Platform Power Limit 2 programming. If disabled, the BIOS programs the default Platform Power Limit 2 values. |
| Power Limit 4 Override | Disabled | Enables/disables PL4 override; when disabled, BIOS leaves default Power Limit 4 values. Popup choices Disabled, Enabled. |
| C states | Enabled | Enables/disables CPU power management allowing C-states when the CPU is not 100% utilized. Popup choices Disabled, Enabled. |
| Enhanced C-states | Enabled | Enables/disables C1E. When enabled, the CPU switches to minimum speed when all cores enter a C-state. |
| C-State Auto Demotion | C1 | — |
| C-State Un-demotion | C1 | Configure C-state un-demotion. |
| Package C-State Demotion | Enabled | Package C-state demotion. |
| Package C-State Un-demotion | Enabled | Package C-state un-demotion. |
| CState Pre-Wake | Enabled | Disabling sets bit 30 of POWER_CTL MSR (0x1FC) to 1 to disable C-state pre-wake. |
| Package C State Limit | Auto | Maximum package C-state limit. **Cpu Default** leaves the factory default; **Auto** initializes the deepest available package C-state limit. |
| EC Turbo Control Mode | Disabled | Enables/disables EC Turbo control mode. |

Latency-control fields on the lower portion of the page:

| Group | Time Unit shown | Latency shown |
|---|---|---|
| C6/C7 Long Latency Control (MSR 0x60C) | 1024 ns | 0 |
| C8 Latency Control (MSR 0x633) | 1024 ns | 0 |
| C9 Latency Control (MSR 0x634) | 1024 ns | 0 |
| C10 Latency Control (MSR 0x635) | 1024 ns | 0 |

**Additional field and navigation help**

| Setting / entry | Help / captured choices |
|---|---|
| C6/C7 Long Latency Control → Time Unit | Unit of measurement for the IRTL value, bits [12:10]. |
| C6/C7 Long Latency Control → Latency | Interrupt Response Time Limit value, bits [9:0]; enter **0–1023**. |
| C8 Latency Control → Time Unit | Unit of measurement for the IRTL value, bits [12:10]. |
| C8 Latency Control → Latency | Interrupt Response Time Limit value, bits [9:0]; enter **0–1023**. |
| C9 Latency Control → Time Unit | Unit of measurement for IRTL, bits [12:10]. |
| C9 Latency Control → Latency | Interrupt Response Time Limit, bits [9:0]; enter **0–1023**. |
| C10 Latency Control → Time Unit | Unit of measurement for IRTL, bits [12:10]. |
| C10 Latency Control → Latency | Interrupt Response Time Limit, bits [9:0]; enter **0–1023**. |

Submenus:

| Submenu | Coverage |
|---|---|
| View/Configure Turbo Options | Captured below |
| Config TDP Configurations | Captured below |
| Custom P-state Table | Captured below |
| Power Limit 3 Settings | Captured below |
| CPU Lock Configuration | Captured below |

##### View/Configure Turbo Options

Path: `Advanced > Power & Performance > CPU - Power Management Control > View/Configure Turbo Options`. Page heading: **Current Turbo Settings**.

Menu help: View/configure turbo options.

| Information field | Shown value |
|---|---|
| Max Turbo Power Limit | 4095.875 |
| Min Turbo Power Limit | 0.0 |
| Package TDP Limit | 15.0 |
| Power Limit 1 | 18.0 |
| Power Limit 2 | 35.0 |

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| Energy Efficient P-state | Enabled | Enables/disables Energy Efficient P-state. **0** disables access to ENERGY_PERFORMANCE_BIAS MSR and CPUID Function 6 ECX[3] reads 0 (no policy support). **1** enables access to ENERGY_PERFORMANCE_BIAS MSR **1B0h** and CPUID Function 6 ECX[3] reads 1 (policy support). |
| Package Power Limit MSR Lock | Disabled | Enables/disables locking Package Power Limit settings. Enabling locks PACKAGE_POWER_LIMIT MSR; a reset is required to unlock it. |
| Energy Efficient Turbo | Enabled | Opportunistically lowers turbo frequency to improve efficiency. The BIOS recommends disabling only for overclocking situations requiring a constant turbo frequency and otherwise leaving it enabled. |

Submenu: **Turbo Ratio Limit Options**.

###### Turbo Ratio Limit Options

Path: `Advanced > Power & Performance > CPU - Power Management Control > View/Configure Turbo Options > Turbo Ratio Limit Options`.

The page contains a **Current Turbo Ratio Limit Settings** block and a configurable block.

| Index N | Current NumcoreN | Current RatioN | Configured NumcoreN | Configured RatioN |
|---|---|---|---|---|
| 0 | 1 | 38 | 1 | 38 |
| 1 | 2 | 37 | 2 | 37 |
| 2 | 3 | 35 | 3 | 35 |
| 3 | 4 | 35 | 4 | 35 |
| 4 | 5 | 33 | 5 | 33 |
| 5 | 6 | 32 | 6 | 32 |
| 6 | 7 | 31 | 7 | 31 |
| 7 | 8 | 30 | 8 | 30 |

**Additional field and navigation help**

| Setting / entry | Help / captured choices |
|---|---|
| E-core Turbo Ratio Limit Numcore0 | Defines the core range whose turbo ratio is set by Ratio0. If Numcore0 is zero, the entry is ignored. |
| E-core Turbo Ratio Limit Ratio7 | Defines the turbo ratio for the core range in Numcore7. The printed maximum is **85**, irrespective of core extension mode. |

##### Config TDP Configurations

Path: `Advanced > Power & Performance > CPU - Power Management Control > Config TDP Configurations`.

Menu help: Configurable Processor Base Power (cTDP) configurations.

| Setting / information field | Shown value | Help / captured choices |
| --- | --- | --- |
| Enable Configurable TDP | Applies to cTDP | Applies configurable Processor Base Power initialization according to non-cTDP/cTDP. The help calls **1 / Applies to cTDP** the default; **0** applies non-cTDP and bypasses BIOS cTDP initialization. |
| Configurable TDP Boot Mode | Nominal | Describes **Nominal / Level1 / Level2 / Deactivate** selection. Deactivate sets MSR to Nominal and MMIO to zero. These are help-listed choices; an open choice popup was not captured. |
| Configurable TDP Lock | Disabled | — |
| CTDP BIOS control | Disabled | Enables cTDP control through runtime ACPI BIOS methods. This BIOS-only feature does not require EC or driver support. |
| ConfigTDP Levels | 2 | — |
| ConfigTDP Turbo Activation Ratio | 17 (Unlocked) | — |
| Power Limit 1 | 18.0W (MSR:18.0) | — |
| Power Limit 2 | 35.0W (MSR:35.0) | — |

| Field | Custom Settings Nominal | Custom Settings Level1 |
|---|---|---|
| ConfigTDP Nominal / ConfigTDP Level1 information | Ratio:18 TAR:17 PL1:15.0W | Ratio:10 TAR:9 PL1:9.0W |
| Power Limit 1 | 18000 | 0 |
| Power Limit 2 | 35000 | 0 |
| Power Limit 1 Time Window | 0 | 0 |
| ConfigTDP Turbo Activation Ratio | 0 | 0 |

Custom Power Limit 1/2 inputs are **milliwatts**, rounded to the nearest **1/8 W**, with **0 meaning no custom override**. Thus 18000 means 18 W and 35000 means 35 W. The PL1 Time Window is **seconds**, range **0–128**, with 0 selecting the firmware default. Help and SKU-dependent constraints are included below; this generic help does not establish additional numerical limits for this board.

**Additional field and navigation help**

| Setting / entry | Help / captured choices |
|---|---|
| Custom Settings Nominal / Level1 → Power Limit 1 | **Milliwatts**, rounded by the BIOS to the nearest **1/8 W**. **0 = no custom override**; example: 12.50 W → 12500. Overclocking SKU: between maximum/minimum limits in PACKAGE_POWER_SKU_MSR. Other SKUs: between minimum power limit and Processor Base Power (TDP). A help scrollbar is visible. |
| Custom Settings Nominal / Level1 → Power Limit 2 | **Milliwatts**, rounded to nearest **1/8 W**. **0 = no custom override**; 12.50 W → 12500. Processor control policies keep package power from exceeding this limit. |
| Custom Settings Nominal / Level1 → Power Limit 1 Time Window | **Seconds**, **0–128**. **0 = default**, described as 28 seconds for Mobile and 8 seconds for Desktop. Defines the time window for maintaining Processor Base Power (TDP). |
| Custom Settings Nominal / Level1 → ConfigTDP Turbo Activation Ratio | Custom turbo activation ratio, valid from **LFM to Max Turbo**. **0 = do not use a custom value**. |

##### Custom P-state Table

Path: `Advanced > Power & Performance > CPU - Power Management Control > Custom P-state Table`.

Menu help: Add a custom P-state table.

| Setting | Shown value | Help / captured choices |
|---|---|---|
| Number of P states | 0 | Sets the number of custom P-states. At least **2 states** must be present. |

Only this field is visible with the shown value of 0. Additional per-state fields in a populated custom table were not captured.

##### Power Limit 3 Settings

Path: `Advanced > Power & Performance > CPU - Power Management Control > Power Limit 3 Settings`.

Menu help: Power Limit 3 settings.

| Setting | Shown value | Help / captured choices |
|---|---|---|
| Power Limit 3 Override | Disabled | Enables/disables PL3 override. If disabled, the BIOS leaves hardware defaults for Power Limit 3 and its Time Window. |

##### CPU Lock Configuration

Path: `Advanced > Power & Performance > CPU - Power Management Control > CPU Lock Configuration`.

Menu help: CPU lock configuration.

| Setting | Shown value | Help / captured choices |
|---|---|---|
| CFG Lock | Enabled | Configures the CFG Lock bit of **MSR 0xE2[15]**. Popup choices Enabled, Disabled. |
| Overclocking Lock | Enabled | Enables/disables Overclocking Lock, bit 20 of FLEX_RATIO(194) MSR. |

#### GT - Power Management Control

Path: `Advanced > Power & Performance > GT - Power Management Control`.(repeated view).

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| RC6(Render Standby) | Enabled | Enables render-standby support. |
| Maximum GT frequency | Default Max Frequency | — |
| Disable Turbo GT frequency | Disabled | — |

### Trusted Computing

Path: `Advanced > Trusted Computing`.

Menu help: Trusted Computing settings.

| Information field | Shown value |
|---|---|
| Device status | TPM 2.0 Device Found |
| Firmware Version | 600.18 |
| Vendor | INTC |
| Active PCR banks | SHA256 |
| Available PCR banks | SHA256, SHA384, SM3 |

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| TPM Device Support | Enable | Enables/disables BIOS support for the security device. With support disabled, the OS does not show the security device, and TCG EFI protocol / INT1A interface are unavailable. |
| TPM 2.0 InterfaceType | CRB | — |

The available PCR banks are an explicitly displayed capability list, not an open selection list.

### ACPI Settings

Path: `Advanced > ACPI Settings`.

Menu help: System ACPI parameters.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| Enable ACPI Auto Configuration | Disabled | — |
| Enable Hibernation | Enabled | Enables/disables system hibernation, OS/S4 Sleep State. May not be effective with some operating systems. |
| ACPI Sleep State | S3 (Suspend to RAM) | Highest ACPI sleep state entered when the SUSPEND button is pressed. |

### Runtime Error Logging Settings

Path: `Advanced > Runtime Error Logging Settings`.

Menu help: Runtime error logging settings.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| Runtime Error Logging System Enabling | Disabled | Enables/disables the runtime error logging system. |

### IT8613 Super IO Configuration

Path: `Advanced > IT8613 Super IO Configuration`.

Menu help: System Super IO chip parameters.

Information: **Super IO Chip = IT8613**. Submenu: **Serial Port 1 Configuration**.

#### Serial Port 1 Configuration

Path: `Advanced > IT8613 Super IO Configuration > Serial Port 1 Configuration`.

Menu help: Set parameters of Serial Port 1 (COMA).

| Setting / information field | Shown value | Help / captured choices |
| --- | --- | --- |
| Serial Port | Enabled | — |
| Device Settings (information) | IO=3F8h; IRQ=4; | — |
| Change Settings | Auto | Select optimal settings for the Super IO device. |

### Hardware Monitor

Path: `Advanced > Hardware Monitor`. Page heading: **Pc Health Status**.

Menu help: Monitor hardware status.

| Sensor / information field | Shown reading |
|---|---|
| System temperature1 | +43; following unit glyph is rendered as an unreadable/question-mark box |
| Fan Speed | N/A |
| V3.3A | +3.344 V |
| VIN1 | +1.298 V |
| VIN2 | +3.322 V |
| VCC3V | +3.300 V |
| VBAT | +2.992 V |

These are momentary readings, not configured limits. shows VIN1 at +1.287 V rather than +1.298 V. **Smart Fan Function** is documented below.

#### Smart Fan Function

Path: `Advanced > Hardware Monitor > Smart Fan Function`. Page heading: **Fan Setting**.

Menu help: Smart Fan function settings.

| Setting | Shown value | Help / captured choices |
|---|---|---|
| Smart Fan Mode | Automatic Mode | Smart Fan Mode selection. |
| Fan Type | PWM | Select fan type RPM/PWM. Popup choices **PWM, RPM**. |
| Fan start/off temperature limit | 40 | Fan runs when temperature is higher than this limit. |
| Fan automatic start temperature limit | 55 | Fan uses START PWM until this limit; PWM starts rising automatically above it. |
| Fan full speed temperature limit | 80 | Fan runs at full speed when temperature is higher than this limit. |
| Fan start PWM | 127 | Fan starts with this PWM value. The BIOS does not label it as a percentage. |
| PWM SLOPE SETTING | 16 | PWM slope selection. No equation or numeric range printed here. |
| Δ Temperature | 0 | Temperature interval. |
| Smoothing control | 4Hz | Smoothing frequency selection. |

Temperature units and numeric-field limits are not printed in the captured fan help. The reference preserves the raw values rather than assigning an unshown unit or PWM scale. Automatic Mode is a shown selection whose full choice list was not opened. Fan Type choices PWM and RPM are captured.

### RTC Alarm

Path: `Advanced > RTC Alarm`.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| RTC Alarm | Disabled | Enables/disables waking on an alarm. **FixedTime** wakes at a specified hour:minute:second. **DynamicTime** wakes at current time plus an Increase minute(s) value. Those extra fields are not displayed with RTC Alarm disabled. |

No alarm date/time fields are visible in this disabled state.

### Serial Port Console Redirection

Path: `Advanced > Serial Port Console Redirection`.

Menu help: Serial-port console redirection.

| Group | Setting | Shown value |
|---|---|---|
| COM0 | Console Redirection | Disabled |
| Serial Port for Out-of-Band Management / Windows Emergency Management Services (EMS) | Console Redirection EMS | Disabled |

Two separate **Console Redirection Settings** submenu entries are visible, one under COM0 and one under EMS. Neither submenu's contents were captured. Both entries appear in black text with redirection Disabled; the owner reports some black entries could not be selected. Their availability after changing settings was not tested. A **Legacy Console Redirection** heading is also visible, without a value or captured child settings.

**Additional field and navigation help**

| Setting / entry | Help / captured choices |
|---|---|
| COM0 > Console Redirection | Enable/disable console redirection. |
| Console Redirection EMS | Enable/disable console redirection. Popup choices Disabled, Enabled in . |

### PCI Subsystem Settings

Path: `Advanced > PCI Subsystem Settings`.

Menu help: PCI subsystem settings.

Information: **AMI PCI Driver Version = A5.01.28**.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| Re-Size BAR Support | Disabled | Enables/disables Resizable BAR support if the system has capable PCIe devices. |
| BME DMA Mitigation | Disabled | Help describes re-enabling the Bus Master Attribute disabled during PCI enumeration for PCI bridges after SMM is locked. |

The page also contains the heading **Change Settings of the Following PCI Devices**, but no individual devices are listed in this view. Its on-screen notice says changing PCI device settings can cause unwanted side effects or a system hang.

### USB Configuration

Path: `Advanced > USB Configuration`.

Menu help: USB configuration parameters.

| Information field | Shown value |
|---|---|
| USB Module Version | 32 |
| USB Controllers | 1 XHCI |
| USB Devices | 2 Keyboards, 1 Mouse |

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| Legacy USB Support | Enabled | Enabled provides legacy USB support. Auto disables legacy support if no USB devices are connected. Disabled keeps USB devices available only for EFI applications. Popup choices **Enabled, Disabled, Auto**. |
| XHCI Hand-off | Enabled | Workaround for operating systems without XHCI hand-off support. XHCI ownership change should be claimed by the XHCI driver. |
| USB Mass Storage Driver Support | Enabled | Enables/disables USB mass-storage driver support. |

### Network Stack Configuration

Path: `Advanced > Network Stack Configuration`.

Menu help: Network stack settings.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| Network Stack | Disabled | Enables/disables the UEFI network stack. |

No further network-stack settings are visible in this state.

### NVMe Configuration

Path: `Advanced > NVMe Configuration`.

Menu help: NVMe device option settings.

Status: **No NVME Device Found**. No drive-specific settings are displayed. This is a different menu from the separately listed **Generic NVMe PCIe SSD Configuration Data** entry on the Advanced page.

### SDIO Configuration

Path: `Advanced > SDIO Configuration`.

Menu help: SDIO configuration parameters.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| SDIO Access Mode | Auto | Auto uses DMA if supported, otherwise PIO; the help generically describes DMA and PIO. The actual popup in lists **Auto, ADMA, SDMA, PIO**. The help does not separately explain ADMA versus SDMA. |

Only this setting is visible. A scrollbar is present; any additional content outside this view is not established by the screen.

### Intel Ethernet controller information

Paths: the two `Advanced > Intel(R) Ethernet Controller I226-V` entries.

Menu help: Configure Gigabit Ethernet device parameters (BIOS wording).

| Information field | Controller ending E6 | Controller ending E7 |
|---|---|---|
| UEFI Driver | Intel(R) 2.5G Ethernet Controller 0.10.06 | Intel(R) 2.5G Ethernet Controller 0.10.06 |
| Device Name | Intel(R) Ethernet Controller I226-V | Intel(R) Ethernet Controller I226-V |
| Link Status | Disconnected | Disconnected |
| MAC Address | <this board's MAC> | <this board's MAC> |

No configurable fields or further submenus appear in these views. Which RJ45 socket has which MAC isn't shown.

### Generic NVMe PCIe SSD Configuration Data

Path: `Advanced > Generic NVMe PCIe SSD Configuration Data`.

Menu help: Manage Generic Express Flash NVMe PCIe SSD.

Entry: **View Physical Device Properties**. Help: display the physical device properties.

Child path: `Advanced > Generic NVMe PCIe SSD Configuration Data > View Physical Device Properties`.

| Information field | Shown value |
|---|---|
| Model Number | SAMSUNG MZ1LB960HAJQ-00007 |
| Firmware Revision | EDA7602Q |
| Capacity (GB) | 960 |

This generic/vendor menu reports a Samsung drive while the separate AMI NVMe Configuration page reports no device. Both observations are preserved; the screens do not explain the differing inventories.

### Driver Health

Path: `Advanced > Driver Health`.

Menu help: Provides health status for drivers/controllers.

| Driver entry | Shown health |
|---|---|
| Intel(R) 2.5G Ethernet Controller 0.10.06 — first instance | Healthy |
| Intel(R) 2.5G Ethernet Controller 0.10.06 — second instance | Healthy |
| Samsung Electronics NVMe Driver | Healthy |

The child Ethernet views show two **Intel(R) Ethernet Controller I226-V** entries, both **Healthy**. The Samsung child view shows **Samsung NVM Express Controller — Healthy**. The screenshots do not map those child entries to physical ports. Help describes providing health status for drivers/controllers.

## Chipset

 Submenus: **System Agent (SA) Configuration** and **PCH-IO Configuration**.

### System Agent (SA) Configuration

Path: `Chipset > System Agent (SA) Configuration`.(repeated view).

Information: **VT-d = Supported**. Submenus: **Memory Configuration** and **Graphics Configuration**.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| VT-d | Enabled | VT-d capability. |
| IGD VTD Enable | Enabled | Enables/disables IGD VTD. |
| IPU VTD Enable | Enabled | Enables/disables IPU VTD. |
| IOP VTD Enable | Enabled | Enables/disables IOP VTD. Popup choices Enabled, Disabled. |
| Control Iommu Pre-boot Behavior | Enable IOMMU during boot | Enables IOMMU in the preboot environment if the DMAR table is installed in DXE and VTD_INFO_PPI is installed in PEI. |

#### Memory Configuration

Path: `Chipset > System Agent (SA) Configuration > Memory Configuration`.

| Information field | Shown value |
|---|---|
| Memory RC Version | 0.0.4.73 |
| Memory Frequency | 4800 MHz |
| tCL-tRCD-tRP-tRAS | 40-39-39-77 |
| MC 0 Ch 0 DIMM 0 | Populated & Enabled |
| MC 0 Ch 0 DIMM 0 → Size | 49152 MB (DDR5) |
| MC 0 Ch 0 DIMM 0 → Number of Ranks | 2 |
| MC 0 Ch 0 DIMM 0 → Manufacturer | Micron |
| MC 0 Ch 0 DIMM 1 | Not Populated / Disabled |
| MC 1 Ch 0 DIMM 0 | Not Populated / Disabled |
| MC 1 Ch 0 DIMM 1 | Not Populated / Disabled |

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| SA GV | Disabled | System Agent Geyserville can be disabled, fixed to a specific point, or enabled for frequency switching. |
| In-Band ECC Support | Disabled | Enables/disables In-Band ECC; help says it will be enabled if memory has a symmetric configuration. |
| Memory Remap | Enabled | Enables/disables memory remapping above 4 GB. |
| Time Measure | Disabled | Enables/disables printing the time required to execute MRC. |

The DIMM labels above are firmware labels, not an assertion that the board has four physical memory sockets.

#### Graphics Configuration

Path: `Chipset > System Agent (SA) Configuration > Graphics Configuration`.(overlapping views; the second reveals the last submenu).

Menu help: Graphics configuration.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| Graphics Turbo IMON Current | 31 | Help lists supported values **14–31**; shown value is 31. |
| Skip Scaning of External Gfx Card | Disabled | If enabled, BIOS does not scan external graphics on PEG and PCH PCIe ports. |
| Primary Display | Auto | Help lists IGFX, PEG and PCI for primary graphics, or HG for Hybrid Gfx. |
| Internal Graphics | Auto | — |
| GTT Size | 8MB | Selects GTT size. |
| Aperture Size | 256MB | An aperture greater than 2048 MB automatically enables Above 4 GB MMIO BIOS assignment. Help instructs disabling CSM Support to use this feature. |
| PSMI SUPPORT | Disabled | Enables/disables PSMI. |
| DVMT Pre-Allocated | 60M | Selects DVMT 5.0 preallocated (fixed) graphics memory for the internal graphics device. |
| Intel Graphics Pei Display Peim | Enabled | Enables/disables PEI (early) display. |
| VDD Enable | Enabled | Enables/disables forcing VDD in BIOS. |
| Configure GT for use | Enabled | Enables/disables GT configuration in BIOS. |
| RC1p Support | Disabled | Enables/disables RC1p. When enabled, sends an RC1p frequency request to PMA when other conditions are met. |
| PAVP Enable | Enabled | Enables/disables PAVP. |
| Cdynmax Clamping Enable | Disabled | Enables/disables Cdynmax clamping. |
| Cd Clock Frequency | Max CdClock freq based on Reference Clk | Selects the highest Cd Clock frequency supported by the platform. |
| VBT Select | DP & HDMI | Selects VBT for the GOP driver and display priority in BIOS. The exact trailing wording is “when all display port is in.” Popup choices **HDMI, DP, DP & HDMI**; shown DP & HDMI. |
| Enable Display Audio Link in Pre-OS | Disabled | Enables/disables the display audio link before the OS starts. |
| IUER Button Enable | Disabled | — |

Submenus: **External Gfx Card Primary Display Configuration**, **LCD Control**, and **Intel(R) Ultrabook Event Support**.

##### External Gfx Card Primary Display Configuration

Path: `Chipset > System Agent (SA) Configuration > Graphics Configuration > External Gfx Card Primary Display Configuration`.

Menu help: Navigation to external graphics primary-display configuration.

The submenu was shown. It contains its heading but **no settings or devices are displayed** in the captured state.

##### LCD Control

Path: `Chipset > System Agent (SA) Configuration > Graphics Configuration > LCD Control`.

Menu help: Navigation to LCD Control.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| Primary IGFX Boot Display | VBIOS Default | — |
| LCD Panel Type | VBIOS Default | Selects the LCD panel used by the internal graphics device. |
| Panel Scaling | Auto | Selects LCD panel scaling for the internal graphics device. |
| Backlight Control | PWM Normal | Backlight control setting. |
| Active LFP | eDP Port-A | Help lists No LVDS (VBIOS does not enable LVDS), Int-LVDS (integrated encoder), SDVO LVDS (SDVO encoder), eDP Port-A (internal DisplayPort encoder from Port-A), and **eDP Port-D** (internal DisplayPort encoder from Port-D through PCH). These are help-listed choices; a selector popup was not opened. |
| Panel Color Depth | 18 Bit | Selects LFP panel color depth. |
| Backlight Brightness | 255 | Sets VBIOS brightness; range **0–255**. |

##### Intel(R) Ultrabook Event Support

Path: `Chipset > System Agent (SA) Configuration > Graphics Configuration > Intel(R) Ultrabook Event Support`.

Menu help: Navigation to Intel Ultrabook event support.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| IUER Slate Enable | Disabled | Enables/disables IUER slate functionality. |
| IUER Dock Enable | Disabled | Enables/disables IUER dock functionality. |

### PCH-IO Configuration

Path: `Chipset > PCH-IO Configuration`.

Submenus: **PCI Express Configuration**, **SATA Configuration**, **SerialIo Configuration**, and **SCS Configuration**.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| Wake on LAN Enable | Enabled | Enables/disables integrated LAN waking the system. |
| USB port power under S5 | Enabled | Enables/disables USB port power in S5. |
| State After G3 | S5 State | Selects the state entered when power is reapplied after a power failure (G3). |
| Enable TCO Timer | Disabled | When disabled, disables the PCH ACPI timer, stops the TCO timer and does not publish the ACPI WDAT table. |

These entries record configured power behaviour. In particular, USB power under S5 being enabled does not by itself demonstrate successful USB/CEC wake from shutdown.

#### PCI Express Configuration

Path: `Chipset > PCH-IO Configuration > PCI Express Configuration`.

Menu help: PCI Express configuration settings.

| Setting | Shown value |
|---|---|
| DMI Link ASPM Control | Auto |

All twelve root-port labels are present. Their displayed status or submenu availability is:

| Entry | What is shown |
|---|---|
| PCI Express Root Port 1 | Lane configured as USB/SATA/UFS |
| PCI Express Root Port 2 | Lane configured as USB/SATA/UFS |
| PCI Express Root Port 3 | Submenu; captured |
| PCI Express Root Port 4 | Submenu; captured |
| PCI Express Root Port 5 | Not present in this SKU |
| PCI Express Root Port 6 | Not present in this SKU |
| PCI Express Root Port 7 | Submenu; captured |
| PCI Express Root Port 8 | Not present in this SKU |
| PCI Express Root Port 9 | Submenu; captured |
| PCI Express Root Port 10 | Shadowed by x2/x4 port |
| PCI Express Root Port 11 | Shadowed by x2/x4 port |
| PCI Express Root Port 12 | Shadowed by x2/x4 port |
| PCIE clocks | Submenu; captured |

**Additional field and navigation help**

| Setting / entry | Help / captured choices |
|---|---|
| Root-port entries | PCI Express root-port settings. |

##### PCI Express Root Ports 3, 4, 7 and 9

Paths: `Chipset > PCH-IO Configuration > PCI Express Configuration > PCI Express Root Port N`.

| Setting | Port 3 | Port 4 | Port 7 | Port 9 |
|---|---|---|---|---|
| PCI Express Root Port N | Enabled | Enabled | Enabled | Enabled |
| Connection Type | Built-in | Built-in | Built-in | Slot |
| ASPM | Disabled | Disabled | Disabled | Disabled |
| L1 Substates | L1.1 & L1.2 | L1.1 & L1.2 | L1.1 & L1.2 | L1.1 & L1.2 |
| L1 Low | Enabled | Enabled | Enabled | Enabled |
| Hot Plug | Disabled | Disabled | Disabled | Disabled |
| PCIe Speed | Auto | Auto | Auto | Auto |

Each column records a separate captured submenu. `L1 Substates` and `L1 Low` values are preserved even though `ASPM` is shown as disabled; the screens do not establish which settings are effective at runtime.

**Additional field and navigation help**

| Setting / entry | Help / captured choices |
|---|---|
| Root Port 3 > ASPM | Help lists Force L0s (force all links into L0s), Auto (BIOS automatically configures), and Disable (disables ASPM). |
| Root Port 3 > L1 Substates | PCI Express L1 substate settings. |
| Root Port 3 > L1 Low | Enables/disables PCI Express L1 Low substate. |
| Root Port 3 > PCIe Speed | Configures PCIe speed. |
| Root Port 3 > PCI Express Root Port 3 | Controls the root port. |
| Root Port 4 / 7 / 9 > PCI Express Root Port | Controls the respective root port. |

##### PCIE clocks

Path: `Chipset > PCH-IO Configuration > PCI Express Configuration > PCIE clocks`.

Menu help: Navigation to PCIe clocks.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| ClkReq for Clock0 | Platform-POR | **Platform-POR** assigns CLKREQ to CLKSRC according to board layout; **Disabled** does not use CLKREQ. |

#### SATA Configuration

Path: `Chipset > PCH-IO Configuration > SATA Configuration`.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| SATA Controller(s) | Enabled | Enables/disables the SATA device. |
| SATA Mode Selection | AHCI | Determines how SATA controllers operate. |

Only **Serial ATA Port 1** is shown on this page:

| Port 1 setting / information field | Shown value | Help / captured choices |
| --- | --- | --- |
| Serial ATA Port 1 (status) | Empty | — |
| Software Preserve (information) | Unknown | — |
| Port 1 | Enabled | — |
| Hot Plug | Disabled | Designates this port as hot-pluggable. |
| Configured as eSATA (information) | Hot Plug supported | — |
| External | Disabled | Marks this port as external. |
| Spin Up Device | Disabled | If enabled on any ports, staggered spin-up is performed and only drives with this option enabled spin up at boot; otherwise all drives spin up at boot. |
| SATA Device Type | Hard Disk Drive | Identifies whether the SATA port connects to a solid-state drive or hard disk drive. |
| Topology | Unknown | Identifies topology; help lists Default, ISATA, Flex, DirectConnect and M2. |
| SATA Port 1 DevSlp | Disabled | Enables/disables DevSlp. Help says both drive and SATA port must support DevSlp and instructs checking board design before enabling it. |
| DITO Configuration | Disabled | Enables/disables DITO configuration. Popup choices Disabled, Enabled. DITO Value 625 and DM Value 15 appear in black text while configuration is Disabled; their own help is not captured. |
| DITO Value | 625 | — |
| DM Value | 15 | — |

The `Configured as eSATA` line is transcribed as displayed; it is not the same field as the disabled `Hot Plug` setting. The screen does not map this firmware port to the board's physical SATA sockets or inventory all attached SATA controllers.

#### SerialIo Configuration

Path: `Chipset > PCH-IO Configuration > SerialIo Configuration`.

Menu help: SerialIo configuration settings.

| Setting | Shown value |
|---|---|
| I2C0 Controller | Enabled |
| I2C1 Controller | Enabled |

Submenus: **Serial IO I2C0 Settings** and **Serial IO I2C1 Settings**.

**Additional field and navigation help**

| Setting / entry | Help / captured choices |
|---|---|
| Serial IO I2C0 Settings / Serial IO I2C1 Settings | Configure the SerialIo controller. |

##### Serial IO I2C0 Settings

Path: `Chipset > PCH-IO Configuration > SerialIo Configuration > Serial IO I2C0 Settings`.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| Set Serial IO I2C #0 Speed | 400 KHz | Selects I2C speed; BIOS only passes the speed value to the OS driver through ACPI. |

Submenu: **Serial IO Touch Panel Settings**.

###### Serial IO Touch Panel Settings

Path: `Chipset > PCH-IO Configuration > SerialIo Configuration > Serial IO I2C0 Settings > Serial IO Touch Panel Settings`.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| Touch Panel | Disabled | Indicates the type of I2C touch panel connected to the SerialIo controller. |

##### Serial IO I2C1 Settings

Path: `Chipset > PCH-IO Configuration > SerialIo Configuration > Serial IO I2C1 Settings`.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| Set Serial IO I2C #1 Speed | 400 KHz | Selects I2C speed; BIOS only passes the speed value to the OS driver through ACPI. |

#### SCS Configuration

Path: `Chipset > PCH-IO Configuration > SCS Configuration`.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| eMMC 5.1 Controller | Enabled | — |
| eMMC 5.1 HS400 Mode | Enabled | Enables/disables SCS eMMC 5.1 HS400 mode. |
| Enable HS400 Software tuning | Disabled | Help says software tuning should improve eMMC HS400 stability at the expense of boot time. |
| Driver Strength | 40 Ohm | Sets I/O driver strength. |

## Security

Path: `Security`.

| Entry / information field | What is shown | Help / captured choices |
| --- | --- | --- |
| Administrator Password | Password-setting entry; no set/unset status displayed | Sets the administrator password. |
| User Password | Password-setting entry; no set/unset status displayed | — |
| Minimum length | 3 | — |
| Maximum length | 20 | — |
| Secure Boot | Submenu; captured below in | — |

The on-screen **Password Description** explains:

- If only the administrator password is set, it limits access to Setup and is requested when entering Setup.
- If only the user password is set, it is a power-on password required to boot or enter Setup; in Setup that user has administrator rights.
- The displayed password-length range is 3–20.

Secure Boot status, mode and key inventory are documented in the child sections below.

### Secure Boot

Path: `Security > Secure Boot`.

| Field / setting / entry | Shown value / type | Help / captured choices |
| --- | --- | --- |
| System Mode | User | — |
| Secure Boot | Disabled | — |
| Secure Boot status | Not Active | — |
| Secure Boot Mode | Custom | Standard or Custom; Custom allows a physically present user to configure Secure Boot policy variables without full authentication. Popup choices Standard, Custom. |
| Restore Factory Keys | Submenu/action entry | — |
| Reset To Setup Mode | Submenu/action entry | — |
| Key Management | Submenu | — |

Secure Boot enable/disable help and key/reset confirmation screens are not captured. The Key Management inventory is documented below.

#### Key Management

Path: `Security > Secure Boot > Key Management`.

| Information / setting | Shown value |
|---|---|
| Vendor Keys | Valid |
| Factory Key Provision | Enabled |

Factory Key Provision help: installs factory-default Secure Boot keys after platform reset while the system is in Setup mode.

Action/navigation entries: **Restore Factory Keys**, **Reset To Setup Mode**, **Enroll Efi Image**, and **Export Secure Boot variables**. Their dialogs and execution are not captured.

| Secure Boot variable | Size (unit not printed) | Keys |
|---|---|---|
| Platform Key (PK) | 1575 | 1 |
| Key Exchange Keys (KEK) | 3066 | 2 |
| Authorized Signatures (db) | 6133 | 4 |
| Forbidden Signatures (dbx) | 17836 | 371 |
| Authorized TimeStamps (dbt) | 0 | 0 |
| OsRecovery Signatures (dbr) | 0 | 0 |

Each variable has a child/action entry. Their individual management screens are not captured. The inventory does not establish the identities of individual certificates/signatures.

## Boot

Path: `Boot`.

| Setting | Shown value | Help / captured choices |
| --- | --- | --- |
| Setup Prompt Timeout | 1 | Seconds to wait for the setup activation key; **65535 (0xFFFF)** means indefinite waiting. Full input range not explicitly printed. |
| Bootup NumLock State | Off | Selects keyboard NumLock state. |
| Enable Boot Logo | On | Controls whether the Hardkernel logo is displayed. |
| Quiet Boot | Enabled | Enables/disables Quiet Boot. |
| Fast Boot | Disabled | Initializes the minimal set of devices needed to launch the active boot option; has no effect for BBS boot options. |
| New UEFI OS Boot Option Policy | Default | Controls placement of newly detected UEFI boot options. |

**Boot Configuration**, **Boot Option Priorities**, and **Driver Option Priorities** are visible headings. No numbered boot-device priorities or individual driver priorities are listed in this captured view.

## Save & Exit

Path: `Save & Exit`. These are action entries, not persistent setting values.

| Group | Action entry | Help / captured choices |
|---|---|---|
| Save Options | Save Changes and Exit | Exits system setup after saving changes. |
| Save Options | Discard Changes and Exit | — |
| Save Options | Save Changes and Reset | — |
| Save Options | Discard Changes and Reset | — |
| Save Options | Save Changes | — |
| Save Options | Discard Changes | — |
| Default Options | Restore Defaults | — |
| Default Options | Save as User Defaults | — |
| Default Options | Restore User Defaults | — |

**Boot Override** is a visible heading with no device entries displayed. No action confirmation dialogs were captured, and the images do not show any of these actions being executed.

## Coverage gaps for a complete firmware reference

All **302 screens** have been reviewed. The owner reports that some black-text entries could not be selected. Entries unavailable in the captured configuration are limitations of access, rather than requests to change settings just for documentation.

| Parent path | Remaining contents/help not captured | Current evidence |
|---|---|---|
| Advanced > CPU Configuration | Performance-core Information | Entry visible; no child screen captured. |
| Advanced > Serial Port Console Redirection | COM0 and EMS Console Redirection Settings | Both entries appear in black text with redirection Disabled. |
| Chipset > PCH-IO Configuration > SATA Configuration | DITO Value and DM Value help, units/ranges | Black-text values 625 and 15 with DITO Configuration Disabled. |
| Security > Secure Boot | Secure Boot enable/disable help; Restore Factory Keys and Reset To Setup Mode help/dialogs | Mode help is resolved by; action help/dialogs remain uncaptured. |
| Security > Secure Boot > Key Management | Enroll Efi Image, Export Secure Boot variables, and individual PK/KEK/db/dbx/dbt/dbr child screens | Parent inventory and Factory Key Provision help are captured. |
| CPU Power Management > Config TDP Configurations | Any remaining scrolled continuation of custom PL1 help | have a help scrollbar; no new PL1 capture in shots3. |

Other limits:

- **Choice lists:** complete open popups are now captured for RTH, EPP Grouping, PL4 Override, C states, CFG Lock, IOP VTD Enable, VBT Select, Fan Type, Legacy USB Support, DITO Configuration, Secure Boot Mode, Console Redirection EMS and SDIO Access Mode. Other settings may have only shown values or help-listed choices.
- **Conditional fields:** populated Custom P-state tables, enabled PL3 override/RTC alarm fields and other alternate states are not captured.
- **Units/ranges:** fan threshold units and PWM scale remain unprinted; Setup Prompt Timeout help confirms seconds and its indefinite-wait sentinel, but does not explicitly state its entire input range.
- **SDIO:** still shows only SDIO Access Mode and a page scrollbar. No additional fields are demonstrated.
- **Defaults and saved state:** screens do not establish that defaults were loaded or changes saved. Popup highlighting is a captured selection, not evidence that a different value was committed.
