#!/bin/bash
# installed by labber setup as /usr/local/sbin/labber-gpu-metrics — NVIDIA GPU metrics
# from nvidia-smi, every 15 s, to /var/lib/labber/metrics/gpu.prom (pushed by Alloy).
# Runs as a service (a loop, not a timer: a timer would log every run to the journal);
# --once writes the file once and exits.
set -u
dir=/var/lib/labber/metrics
mkdir -p "$dir"

# a number, or nothing for nvidia-smi's "[N/A]" / "[Not Supported]"
num() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "$1"; }

# container name of a process, from its cgroup (docker-<id>.scope); empty when not in one
container_of() {
    local id
    id=$(grep -o 'docker-[0-9a-f]\{64\}' "/proc/$1/cgroup" 2>/dev/null | head -1) || return 0
    [[ -n "$id" ]] || return 0
    echo "${names[${id#docker-}]:-}"
}

collect() {
    local out idx name uuid util memutil used total temp power limit fan sm mem reasons
    out=$(nvidia-smi --query-gpu=index,name,uuid,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu,power.draw,power.limit,fan.speed,clocks.sm,clocks.mem,clocks_event_reasons.active \
        --format=csv,noheader,nounits 2>/dev/null) || { echo "gpu_metrics_up 0"; return; }
    echo "gpu_metrics_up 1"
    declare -A gpu_of=()
    while IFS=',' read -r idx name uuid util memutil used total temp power limit fan sm mem reasons; do
        idx=${idx// /}; uuid=${uuid// /}; name=${name# }
        gpu_of[$uuid]=$idx
        local l="gpu=\"$idx\",name=\"$name\""
        local v
        v=$(num "${util// /}")    && echo "gpu_utilization_percent{$l} $v"
        v=$(num "${memutil// /}") && echo "gpu_memory_utilization_percent{$l} $v"
        v=$(num "${used// /}")    && echo "gpu_memory_used_bytes{$l} $(( ${v%.*} * 1048576 ))"
        v=$(num "${total// /}")   && echo "gpu_memory_total_bytes{$l} $(( ${v%.*} * 1048576 ))"
        v=$(num "${temp// /}")    && echo "gpu_temperature_celsius{$l} $v"
        v=$(num "${power// /}")   && echo "gpu_power_watts{$l} $v"
        v=$(num "${limit// /}")   && echo "gpu_power_limit_watts{$l} $v"
        v=$(num "${fan// /}")     && echo "gpu_fan_percent{$l} $v"
        v=$(num "${sm// /}")      && echo "gpu_clock_sm_hertz{$l} $(( ${v%.*} * 1000000 ))"
        v=$(num "${mem// /}")     && echo "gpu_clock_memory_hertz{$l} $(( ${v%.*} * 1000000 ))"
        # clocks lowered for heat: HW slowdown 0x8, SW thermal 0x20, HW thermal 0x40
        reasons=${reasons// /}
        if [[ "$reasons" =~ ^0x[0-9a-fA-F]+$ ]]; then
            echo "gpu_thermal_throttle{$l} $(( (reasons & 0x68) != 0 ))"
        fi
    done <<< "$out"

    # VRAM per process, with its container
    declare -A names=()
    if command -v docker >/dev/null; then
        local cid cname
        while read -r cid cname; do names[$cid]=$cname; done \
            < <(docker ps --no-trunc --format '{{.ID}} {{.Names}}' 2>/dev/null)
    fi
    local gu pid pname pmem
    while IFS=',' read -r gu pid pname pmem; do
        gu=${gu// /}; pid=${pid// /}; pmem=$(num "${pmem// /}") || continue
        [[ -n "$pid" ]] || continue
        pname=${pname# }; pname=${pname##*/}
        echo "gpu_process_memory_used_bytes{gpu=\"${gpu_of[$gu]:-}\",process=\"$pname\",container=\"$(container_of "$pid")\"} $(( ${pmem%.*} * 1048576 ))"
    done < <(nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null)
}

while true; do
    tmp=$(mktemp "$dir/.gpu.prom.XXXXXX") || exit 1
    collect > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$dir/gpu.prom"
    [[ "${1:-}" == --once ]] && exit 0
    sleep 15
done
