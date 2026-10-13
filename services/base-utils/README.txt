Utilities: Homepage (dashboard) and stateless tools. No important data — redeploy rather
than restore; Homepage's config is the only thing worth keeping (PBS covers it).

Services:
  homepage      :3000  dashboard (config in ./homepage/config)
  it-tools      :8081  developer tools (encoding, hashing, converters, …)
  stirling-pdf  :8082  PDF tools (merge, split, compress, OCR)
  openspeedtest :3080  network speed test (:3081 HTTPS)

Before deployment:
  .env — HOMEPAGE_ALLOWED_HOSTS (the names you open Homepage at), STIRLING_LANGS

Moving from another machine: copy Homepage's config/ and images/ into ./homepage/, and
Stirling PDF's trainingData, extraConfigs, customFiles, pipeline into ./stirling-pdf/.

Homepage widgets talk to each app's API over the network, so they work across LXCs.
Container status from other machines needs a read-only docker-socket-proxy there.
