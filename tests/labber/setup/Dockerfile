# A fresh Debian with systemd as PID 1 — the closest Docker gets to a Proxmox LXC
# (both are containers on the host's kernel). Used by tests/labber/run-setup.sh.
# Like a fresh LXC template: root only, curl present (setup's bootstrap needs it).
FROM debian:trixie
ENV container=docker
RUN apt-get update \
    && apt-get install -y --no-install-recommends systemd systemd-sysv dbus curl ca-certificates bats util-linux iproute2 \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl mask getty@tty1.service systemd-firstboot.service systemd-modules-load.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
