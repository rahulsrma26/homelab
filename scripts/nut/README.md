# nut — clean shutdowns on a power cut (NUT)

**Run it** as root on each machine on a UPS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/scripts/nut/install.sh)
```

It asks for the role and the shutdown policy first. Every answer can also be given as a flag, for a re-run without prompts.

| Role | Policy | Does | Typical use |
|---|---|---|---|
| `server` (USB cable here) | `lb` | at low battery: tells the clients, shuts down, then **cuts the UPS output**. Everything restarts with mains, even if mains returned during the shutdown | the last host on a UPS that also powers network gear or an NVR |
| | `fsd-timer` | after N s on battery: shuts down the clients, then itself, then cuts the output | a UPS that only powers servers |
| | `self-timer` | after N s on battery: shuts down only itself; the UPS keeps running | a heavy host on a shared UPS, with no clients |
| `client` | `lb` | shuts down at low battery, or when the server says so | important hosts that should stay up as long as possible |
| | `timer` | shuts down after N s on battery | big loads that should go first |
| `monitor` | — | only reports the UPS (to clients and Home Assistant); never shuts anything down | a small always-on box on the network UPS |

Flags: `--role`, `--policy`, `--timer <s>`, `--ups <name>`, `--server <ip>` (client), `--password <pw>` (client), `--listen <ip>` (server/monitor, default `0.0.0.0`), `--dry-run` (prints the config it would write, passwords hidden), `--yes`.

**What it sets up:**
- **Detection:** finds the UPS over USB (`nut-scanner`, or by USB vendor ID for APC, Eaton and CyberPower). It names the UPS after its vendor.
- **Restart delays:** for USB-HID UPSes on the `lb` and `fsd-timer` policies, it sets `offdelay`/`ondelay`, which make the UPS cut its output and restore it with mains.
- **Users and passwords:** three users in `upsd.users`:
  - `upsmon`, for the host's own monitor;
  - `client`, for the other hosts on this UPS;
  - `homeassistant`, read-only, for Home Assistant's NUT integration.

  Passwords are generated and printed **once**; save them in your password manager. Re-runs keep them.
- **Timers:** through `upssched`; the action is `upsmon -c fsd` or `shutdown`.
- **Alerts:** each power event (on battery, back online, low battery, shutdown, lost contact, replace battery) is logged (`journalctl -t nut`) and **mailed to root**. On Proxmox, root's mail goes through Datacenter → Notifications, e.g. to Telegram.
- **Checks:** that the UPS answers, that upsd listens where the clients expect it, and that the client's login works. A wrong password stops the script with an error.

**Rules:**
- **Same UPS:** a client is only ever on the **same UPS** as its server. A client on another UPS can lose its server, or the switch in between, at the wrong moment.
- **Re-runs:** run it again to change something. It backs up `/etc/nut` to `/etc/nut.bak-<date>` first.
- **Moving the USB cable:** run it on the new server first, then re-run the old one as a `client`. The script then also stops the old server's NUT services.
- **Test once for real:** unplug the UPS from mains and watch the order. For `lb`, wait until low battery, then plug it back in during the shutdown: everything should come back by itself.

**Tested** by `make test-scripts` (CI too) in Debian systemd containers with a simulated UPS:
- server + client + monitor, including the wrong-password check and re-runs keeping the passwords;
- a power cut: the timer client powers off; at low battery, the server powers off;
- `fsd-timer`: the client goes down first, then the server.

Not covered by the test: real USB detection, cutting a real UPS's output, and the mail.
