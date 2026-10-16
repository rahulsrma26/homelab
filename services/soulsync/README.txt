SoulSync — playlists and wanted lists → downloaded, tagged, organised music.
Upstream: https://github.com/Nezreka/SoulSync

Services:
  soulsync  :8008  web app (+ :8888 / :8889 Spotify / Tidal OAuth callbacks)
  slskd     :5030  Soulseek client (COMPOSE_PROFILES in .env: slskd-yes, slskd-vpn, slskd-no)
            :50300 Soulseek peer port (forward it on the router for best results)
  gluetun          slskd-vpn only: slskd's traffic goes through the VPN, or nowhere

slskd-vpn: the guest needs /dev/net/tun. Without a forwarded port from the VPN provider,
peers can't connect in; downloads still work from peers that accept connections.
Switching between slskd-yes and slskd-vpn: `docker rm -f slskd` first (both use that name).

After the first start:
  1. SoulSync → Settings → Downloads: Transfer /app/Transfer, downloads /app/downloads
  2. slskd URL http://slskd:5030, API key = SLSKD_API_KEY (.env)
  3. Soulseek account: SOULSEEK_USERNAME / SOULSEEK_PASSWORD (.env). A name nobody has is
     registered on first login; "INVALIDPASS" in the logs means it's taken
  4. Spotify / Tidal: an app in their developer dashboard, with the redirect URI shown in
     SoulSync → Settings → Connections

Data: config/, data/ (databases), logs/, Staging/, scripts/, slskd/ in this folder.
