Garage — S3-compatible object storage, single node. For data that can be rebuilt
(Forgejo's Actions artifacts, logs and packages); it has no backup of its own.

Services:
  garage  :3900  S3 API (path-style, region "garage"; signed requests only)

Before deployment:
  .env — data folder (GARAGE_DIR: meta/ and data/ inside it), S3 port, bucket name.
         The RPC secret and the bucket's access key are generated.

On first start Garage creates its layout, the bucket and one key with read/write
on it. Clients use: endpoint http://<host>:3900, region garage, path-style
addressing, GARAGE_DEFAULT_ACCESS_KEY / GARAGE_DEFAULT_SECRET_KEY. Keep the key
in .env unchanged afterwards; to rotate it, add a new key with the CLI and
remove the old one.

CLI (more buckets, keys, usage):
  docker compose exec garage /garage status
  docker compose exec garage /garage bucket info <bucket>
  docker compose exec garage /garage key create <name>
  docker compose exec garage /garage bucket allow --read --write <bucket> --key <name>

Moving to another host: stop it, copy GARAGE_DIR and .env, start it there with
the same address. Plain HTTP: allow 3900 only from its clients.
