#!/bin/sh
# installed by labber setup as /etc/update-motd.d/95-labber-health — the login
# message, only when the health check found something that needs attention
f=/var/lib/labber/metrics/labber.prom
[ -r "$f" ] || exit 0
k=$(awk '/^labber_reboot_required / {print $2}' "$f")
s=$(awk '/^labber_restart_required_services / {print $2}' "$f")
u=$(awk '/^labber_security_updates_pending / {print $2}' "$f")
g=$(awk '/^labber_gpu_driver_outdated / {print $2}' "$f")
if [ "${g:-0}" = 1 ]; then echo "*** Reboot needed: the NVIDIA driver was updated (the GPU doesn't work until then)."
elif [ "${k:-0}" = 1 ]; then echo "*** Reboot needed: a newer kernel is installed."; fi
[ "${s:-0}" -gt 0 ] && echo "*** $s service(s) still use outdated libraries — reboot, or: sudo needrestart -r a"
[ "${u:-0}" -gt 0 ] && echo "*** $u security update(s) pending."
exit 0
