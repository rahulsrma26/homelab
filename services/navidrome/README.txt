Navidrome — music server: web player and a Subsonic API for phone/desktop apps.

Services:
  navidrome  :4533  web UI + Subsonic API

Before deployment:
  .env — MUSIC_DIR (read-only), PUID/PGID (owner of ./data)

Data: ./data (navidrome.db, cache). Track paths are stored under /music, so keep
MUSIC_DIR mounted at /music when moving it. First start: create the admin user in the
web UI (or restore ./data to keep users, playlists, play counts).
