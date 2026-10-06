#!/bin/bash
# installed by labber setup as /usr/local/sbin/labber-health-check — is a reboot or
# restart needed, are security updates stuck, do services have updates?
# Writes metrics to /var/lib/labber/metrics/labber.prom (pushed by Alloy).
set -u
kernel=0 services=0 security=0
# the kernel only matters in a VM; an LXC runs the host's kernel
if ! systemd-detect-virt -cq 2>/dev/null; then
    newest=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|^/boot/vmlinuz-||' | sort -V | tail -1)
    [[ -n "$newest" && "$newest" != "$(uname -r)" ]] && kernel=1
fi
if command -v needrestart >/dev/null; then
    services=$(needrestart -b -r l 2>/dev/null | grep -c '^NEEDRESTART-SVC:' || true)
fi
security=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst .*[Ss]ecurity' || true)
# per-service update status from the last `labber check-updates`
# (labber fills in its services folder on install)
updates_metrics=""
updates="@SERVICE_BASE@/.labber-updates"
if [[ -r "$updates" ]]; then
    checked=0
    while IFS=$'\t' read -r svc img cfg ts; do
        [[ -n "$svc" ]] || continue
        updates_metrics+="labber_service_update_available{service=\"$svc\",kind=\"image\"} $([[ $img == yes ]] && echo 1 || echo 0)"$'\n'
        updates_metrics+="labber_service_update_available{service=\"$svc\",kind=\"config\"} $([[ $cfg == yes ]] && echo 1 || echo 0)"$'\n'
        checked="$ts"
    done < "$updates"
    updates_metrics+="labber_updates_checked_timestamp_seconds $checked"$'\n'
fi
dir=/var/lib/labber/metrics
mkdir -p "$dir"
cat > "$dir/labber.prom.tmp" <<PROM
# HELP labber_reboot_required 1 when a newer kernel is installed than the one running
# TYPE labber_reboot_required gauge
labber_reboot_required $kernel
# HELP labber_restart_required_services services still running outdated libraries
# TYPE labber_restart_required_services gauge
labber_restart_required_services $services
# HELP labber_security_updates_pending security updates not yet installed
# TYPE labber_security_updates_pending gauge
labber_security_updates_pending $security
PROM
if [[ -n "$updates_metrics" ]]; then
    {
        echo "# HELP labber_service_update_available 1 when labber check-updates found a newer image or repo config"
        echo "# TYPE labber_service_update_available gauge"
        printf '%s' "$updates_metrics" | grep -v '^labber_updates_checked'
        echo "# HELP labber_updates_checked_timestamp_seconds when labber check-updates last ran"
        echo "# TYPE labber_updates_checked_timestamp_seconds gauge"
        printf '%s' "$updates_metrics" | grep '^labber_updates_checked'
    } >> "$dir/labber.prom.tmp"
fi
mv "$dir/labber.prom.tmp" "$dir/labber.prom"
