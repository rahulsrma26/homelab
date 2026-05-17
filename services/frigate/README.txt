Frigate — NVR with real-time object detection via OpenVINO on Intel iGPU.

Services:
  frigate  :8971  Web UI and API (authenticated)
           :8554  RTSP restreaming
           :8555  WebRTC (TCP + UDP)

Before deployment:
  .env          — set FRIGATE_RTSP_PASSWORD and adjust SHM_SIZE for camera count
  config/config.yml  — add cameras and tweak detection settings

Hardware:
  Requires /dev/dri/renderD128 passed into the LXC (Intel iGPU — VA-API + OpenVINO)
  Storage at /mnt/nvr for recordings and snapshots

SHM size guide:
  1× 1080p  ≈  93 MB
  2× 1080p  ≈ 226 MB
  4× 1080p  ≈ 412 MB
  Default 512mb covers ~4 cameras at 1080p
