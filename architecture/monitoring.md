# Monitoring

One monitoring stack ([`services/monitoring`](../services/monitoring/)) for every host, guest and container, plus Uptime Kuma on a different machine to watch it.

## How data gets there

```
every host and guest:  Alloy ──push──► Prometheus (metrics)
                             └─push──► Loki (logs: journal; containers on Docker hosts)
Proxmox API:  pve-exporter ◄──scrape── Prometheus
Home Assistant: ──► InfluxDB
                       Grafana ◄── dashboards: Proxmox, guests, containers, disks, logs
             Prometheus ──alerts──► Alertmanager ──► Telegram
```

- **Push, not scrape:** each machine runs Grafana Alloy (installed and configured by `labber setup`), which pushes to Prometheus (remote write) and Loki. Nothing needs to reach into the guests, and a new guest reports as soon as it's set up.
- **The monitoring LXC has a NIC in both the management and server VLANs**, so guests in either push to it directly, without firewall exceptions.
- **Placement:** on primary, the low-power host that runs longest on battery, so outages are recorded to the end. Uptime Kuma runs on **backup**, so the two watch each other from different machines; Home Assistant watches too.
- **labber's health check** (hourly and after every package run) writes metrics for reboot-required, services needing a restart, pending security updates and service updates, so they show on the dashboards and raise alerts.

## Alerts

| Group | Alerts |
|---|---|
| hosts and guests | HostDown (scraped targets), **HostNotReporting** (pushed metrics stopped), SystemdUnitFailed, HighCPU, HighMemory |
| maintenance | RebootRequired (newer kernel for over a day), ServicesNeedRestart, SecurityUpdatesStuck, ServiceUpdateAvailable |
| disks | DiskSpaceLow (80%, warning), DiskSpaceCritical (90%), DiskSpaceFull (95%), DiskFillingFast, SmartDriveWear, SmartHealthFailed, ZfsPoolNotOnline |
| memory | MemoryUncorrectableError, MemoryCorrectableErrors (ECC / in-band ECC) |
| containers | ContainerRestarting, ContainerGone, ContainerOOMKilled |

Machines that **push** never report "down"; their samples just stop. HostNotReporting fires on "was reporting before, isn't now". The rules have unit tests (`make test-monitoring`).

## Delivery

Telegram only, timed by severity, so harmless things don't interrupt:

| Severity | When | Repeats |
|---|---|---|
| **critical** | at once | every 6 h while firing |
| **warning** | one digest a day, 15:00–15:30 UTC, listing everything firing | daily |
| **info** (e.g. "update available") | in the daily digest | weekly |

Inhibit rules keep a bigger alert from repeating its smaller ones (e.g. DiskSpaceFull silences DiskSpaceCritical and DiskSpaceLow for the same disk). Proxmox, PBS and TrueNAS send their own notifications (backups, ZFS events, replication) to the same Telegram chat through their notification systems.

**Daily report:** a workflow service collects every alert, has a local LLM summarise them and sends one daily report. Critical alerts keep their direct path, so a broken summariser never hides them.
