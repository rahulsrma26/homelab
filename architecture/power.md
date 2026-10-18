# Power

Three UPSes. On a UPS that powers servers, its USB cable goes to one of them, which runs **NUT** as the server for that UPS; the other machines on the same UPS are its clients. Set up with [`scripts/nut`](../scripts/nut/).

| UPS | Powers | NUT server | Clients |
|---|---|---|---|
| network UPS | router, PoE switch (Wi-Fi APs, Zigbee), core switch | **none**: network gear has nothing to shut down cleanly, so it runs until the battery is empty | — |
| server UPS | managed switches, the camera recorder + cameras, primary, secondary | **primary** | secondary |
| storage UPS | backup, the Synology NAS | **backup** | the NAS |

**A client is only ever on the same UPS as its server.** NUT talks over the network: a client on another UPS could lose its server, or the switch in between, at the wrong moment.

## Shutdown order

Big, unimportant loads go first, so the battery lasts for the network, cameras and primary.

| Machine | Shuts down | How | Why |
|---|---|---|---|
| secondary | after 2 min on battery | only itself | heavy draw, nothing to save; its UPS keeps the recorder and switches up, so it must **not** cut the output |
| backup | after 5 min | the whole UPS (`upsmon -c fsd`) | heavy draw; TrueNAS and PBS need time to stop cleanly; nothing else important on that UPS |
| primary | at low battery | the whole UPS | lowest draw, important data: last to go |

- **Early vs whole-UPS shutdown:** `upsmon -c fsd` shuts the clients, then the server, then cuts the UPS output: right when a UPS powers only servers. A server sharing its UPS with the network or the recorder shuts down only itself.
- On a Proxmox host, `shutdown -h` stops the guests first (guest agent); the timers leave room for that.
- **Alerts:** every power event (on battery, back online, low battery, shutdown, lost contact, replace battery) is logged and mailed to root, which Proxmox forwards to Telegram.

## Coming back

Both are needed on every server:

1. **BIOS: restore on AC power loss = Power On** (not "Last State": after a clean shutdown the last state is *off*).
2. **The UPS cuts its output at the end of the shutdown** and restores it with mains, so every server sees power return, even if mains came back *during* the shutdown. NUT does this (`POWERDOWNFLAG` + Debian's `nutshutdown` hook).

Machines that shut down early (secondary) never lose power if mains returns in time, so they stay off: **Home Assistant wakes them** (Wake-on-LAN when a UPS goes back online).

## Batteries

Lead-acid UPS batteries last 3–5 years, less in a warm spot. Replace by age, and confirm with a **yearly runtime test** (pull mains, note the minutes to low battery). `RB` (replace battery) in `ups.status` means the UPS's own self-test failed: replace then, whatever the age.
