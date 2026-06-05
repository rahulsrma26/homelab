Jellyfin media server with Intel iGPU hardware transcoding.

Services:
  jellyfin  :8096  Web UI and API

Before deployment:
  .env — set PUBLISHED_URL to your external URL

Volumes:
  ./config  — Jellyfin configuration and metadata
  ./cache   — Transcoding cache
  /mnt/media — TrueNAS media mount (bind from LXC config mp0)

Hardware transcoding:
  Dashboard → Playback → Transcoding
  Hardware acceleration: VA-API
  VA-API device: /dev/dri/renderD128
  Enable: H264, HEVC, VP9, AV1
