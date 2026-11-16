pkg-cache — a local cache for downloads every guest repeats: Debian packages (apt-cacher-ng,
port 3142) and Docker Hub images (a pull-through registry mirror, port 5000).

Why: faster installs, updates and CI runs, and Docker Hub's anonymous limit (100 pulls per
6 hours per public IP, shared by every host and CI) is far away. Disposable: nothing to back
up. Eviction: packages nobody asked for in APT_KEEP_DAYS go, and above APT_MAX_GB the least
recently used ones first (to 80 %); image layers go MIRROR_KEEP after they were cached. Sizing:
a home lab needs ~10 GB of packages and ~15–40 GB of images; put CACHE_DIR on a disk or dataset
with a quota (e.g. 128 GB): a full disk would fail downloads through the cache instead of
falling back. Safe: apt checks Debian's signatures, and the templates pull images by
digest, which Docker verifies: a cache can't slip in other content, only fail a download.

Clients (each machine that should use it, as root):
  bash client-setup.sh <cache host>        # apt + Docker; again to change the host
  bash client-setup.sh --remove            # undo
apt asks a 1-second check before each run (/usr/local/bin/pkg-cache-detect): the cache if it
answers, else direct, so a stopped cache never breaks apt. HTTPS repositories (Docker's,
Grafana's) are not cached: apt reaches them directly. Docker gets registry-mirrors (and the
mirror as an insecure registry: plain HTTP inside the LAN) in /etc/docker/daemon.json, the rest
of the file kept; when the mirror doesn't answer, Docker pulls from Docker Hub itself.

Limits: the mirror covers Docker Hub images only (docker.io/…); ghcr.io, quay.io and others go
direct (Docker's mirror setting doesn't apply to them; the rate limit is Docker Hub's anyway).

See it work: http://<host>:3142/acng-report.html (hits and misses), http://<host>:5000/v2/_catalog
(the images it holds).
