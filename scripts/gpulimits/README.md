# gpulimits

NVIDIA power limits and clock caps that survive a reboot. `nvidia-smi -pl` and `-lgc` only last until the next boot; `gpulimits` keeps them in `/etc/gpulimits.conf` and a systemd service applies them at every start. Typical uses: a lower power limit for a quieter, cooler box; a clock cap on one card that runs hot (e.g. one squeezed against another).

| File | |
|---|---|
| `install.sh` | installs `gpulimits` and `gpulimits.service`. Re-run to upgrade (keeps the config). `--uninstall` resets the cards and removes both |
| `gpulimits` | the tool, installed to `/usr/local/sbin/gpulimits` |

Works wherever the NVIDIA driver and systemd are: Debian/Ubuntu, Fedora (incl. atomic desktops: `/usr/local` and `/etc` are writable there), on bare metal or in a VM with the GPUs passed through.

## Install

As root (on a `sudo` machine: `sudo -i` first):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/scripts/gpulimits/install.sh)
```

## Use

```bash
gpulimits status                                   # each card: UUID, PCI address, power (allowed range), clock, cap, temperature
sudo gpulimits set all --power 150                 # every card: 150 W (must be inside the allowed range)
sudo gpulimits set GPU-1234abcd-… --clock 2200     # one card: GPU clock at most 2200 MHz
sudo gpulimits set GPU-1234abcd-… --clock off      # remove that card's cap
sudo gpulimits reset GPU-1234abcd-…                # that card back to the driver's defaults, forgotten
sudo gpulimits reset                               # all cards back to defaults, config removed
```

- **Pick cards by UUID** (`GPU-…` in `status`): it stays the same when the PCI order or the index changes (adding a card, a different slot, or a VM, which may number passed-through cards differently from the host). A PCI bus id or an index work too.
- A line for one card overrides `all` for that setting.
- `set` applies at once and saves; `apply` (what the service runs) re-applies the whole config.
- The cap is the maximum: under load `status` shows the clock at or below it; idle cards clock down as usual.

## Choosing values

- **Power:** `status` shows the allowed range. The minimum is often only 10–20 % below the default (e.g. 150 W of 180 W); lower than that needs a clock cap.
- **Clock cap for a hot card:** watch the temperature under a long load (an hour of games or inference). Lower the cap in 100–200 MHz steps until it stays well below the throttle point (`nvidia-smi -q -d TEMPERATURE`). A cap that keeps a card 10 °C cooler often costs only 5–10 % of its speed, because the last few hundred MHz take the most power.

## Check after a reboot

```bash
systemctl status gpulimits.service      # active (exited); the journal lists each "applied:" line
gpulimits status
```
