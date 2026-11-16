#!/bin/sh
# the cache folder belongs to apt-cacher-ng's user; HTTPS repositories are passed through, not
# cached. Eviction: apt-cacher-ng's own (packages nobody asked for in EX_THRESHOLD days, daily)
# and a size cap, least recently used first: over APT_MAX_GB, the files read longest ago go
# until the cache is 20 % under (atime: relatime updates it at least once a day)
set -e
C=/var/cache/apt-cacher-ng
chown -R apt-cacher-ng:apt-cacher-ng "$C" /var/log/apt-cacher-ng /var/run/apt-cacher-ng 2>/dev/null || true
cap() {
    max=$(( ${APT_MAX_GB:-40} * 1024 * 1024 ))                     # KiB
    used=$(du -sk "$C" | cut -f1)
    [ "$used" -gt "$max" ] || return 0
    target=$(( max * 8 / 10 ))
    find "$C" -type f \( -name '*.deb' -o -name '*.udeb' -o -name '*.ddeb' \) -printf '%A@ %k %p\n' | sort -n |
    while read -r _ k f; do
        [ "$used" -le "$target" ] && break
        rm -f -- "$f" "$f.head"; used=$(( used - k ))
    done
    echo "pkg-cache: over ${APT_MAX_GB:-40} GiB, least recently used packages removed"
}
( n=0; while sleep 3600; do
    cap || true
    n=$((n + 1)); [ $((n % 24)) -eq 0 ] && runuser -u apt-cacher-ng -- /usr/lib/apt-cacher-ng/acngtool maint -c /etc/apt-cacher-ng >/dev/null 2>&1 || true
  done ) &
cap || true
exec runuser -u apt-cacher-ng -- /usr/sbin/apt-cacher-ng -c /etc/apt-cacher-ng \
    ForeGround=1 ExThreshold="${EX_THRESHOLD:-4}" PassThroughPattern='.*' LogDir=/var/log/apt-cacher-ng
