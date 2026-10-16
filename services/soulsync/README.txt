SoulSync — playlists and wanted lists → downloaded, tagged, organised music.
Upstream: https://github.com/Nezreka/SoulSync

Services:
  soulsync  :8008  web app (+ :8888 / :8889 Spotify / Tidal OAuth callbacks)
  slskd     :5030  Soulseek client (optional: COMPOSE_PROFILES in .env)

After the first start:
  1. SoulSync → Settings → Downloads: Transfer /app/Transfer, downloads /app/downloads
  2. slskd URL http://slskd:5030, API key = SLSKD_API_KEY (.env)
  3. slskd's UI (SLSKD_USERNAME / SLSKD_PASSWORD): Options → your Soulseek account
  4. Spotify / Tidal: an app in their developer dashboard, with the redirect URI shown in
     SoulSync → Settings → Connections

Data: config/, data/ (databases), logs/, Staging/, scripts/, slskd/ in this folder.
