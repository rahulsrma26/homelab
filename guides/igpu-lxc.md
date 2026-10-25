# Intel iGPU in an unprivileged LXC

Sharing the host's Intel iGPU with LXCs for video transcoding and OpenVINO inference (Immich, Jellyfin, Frigate). The iGPU stays with the host and several guests can use it at once; nothing is passed through ([architecture/principles.md](../architecture/principles.md)).

## Host

- `i915` loaded (`lsmod | grep i915`) and **not blacklisted**: only NVIDIA drivers are, on hosts that pass a dGPU to a VM.
- `ls -l /dev/dri/` shows `card0` and `renderD128`. Missing with a discrete GPU installed: BIOS → **iGPU Multi-Monitor = Enabled** and **Primary Display = CPU Graphics**.
- **BIOS: RC6 (Render Standby) = Disabled** if a workload decodes continuously at low frame rates: at ~5 fps the iGPU sleeps between frames and fails to wake for the next one (`Failed to sync surface` in Frigate; transcodes failing after idle in Jellyfin).
- **BIOS: DVMT Pre-Allocated = 512 MB** for heavy use: the default 256 MB gave `Can't allocate a surface` with five camera streams decoded plus OpenVINO.

## The LXC

The render node is all an app needs, mapped to the **render group of the guest**:

```bash
pct start <ID>
pct set <ID> -dev0 /dev/dri/renderD128,gid=$(pct exec <ID> -- getent group render | cut -d: -f3)
pct reboot <ID>
```

- The group id must be the guest's (`getent group render` inside it), not the host's: they differ between distributions.
- Some apps also want `card0` (e.g. for display-related checks): `-dev1 /dev/dri/card0,gid=<guest video gid>`.
- Docker inside needs `pct set <ID> --features nesting=1,keyctl=1`; the compose file then passes `/dev/dri` into the container (`devices: - /dev/dri:/dev/dri`).

**Check inside the LXC:**

```bash
apt install -y vainfo && vainfo        # the Intel iHD driver and its H264 / HEVC / VP9 (/ AV1) profiles
```

`intel_gpu_top` doesn't work in an unprivileged LXC (performance counters are blocked): watch usage in the app instead.

## Per app

**Jellyfin:** Dashboard → Playback → Transcoding: **Intel QSV** (or VA-API) with device `/dev/dri/renderD128`; enable the codecs `vainfo` lists; tone mapping for HDR. Media can be mounted read-only.

**Frigate:** detection with **OpenVINO on the iGPU** and decoding with QSV, so no discrete GPU memory is used.
- Set hardware acceleration **only globally**: `ffmpeg: hwaccel_args: preset-intel-qsv-h264`, or `preset-vaapi` if QSV fails to decode (`dec:h264_qsv … Decoding error`, seen on an Iris Xe). Mixing a per-camera preset with a different global one causes `Failed to sync surface` / `hwdownload` crashes.
- One OpenVINO detector is usually enough: a second one on the same iGPU only splits its compute.
- `/tmp/cache` on tmpfs keeps recording-cache writes off the SSD; `shm_size` grows with the cameras (~93 MB per 1080p stream).
- Main stream for recording, sub stream for detection.

**Immich:** the iGPU for video transcoding (QSV, Administration → Video Transcoding → Hardware Acceleration) and for the local machine-learning container (the OpenVINO image), which runs smart search and face recognition on the iGPU. For big re-indexing jobs, a second ML worker on a machine with a discrete GPU can be listed first in Administration → Machine Learning; the local one stays as the fallback.
