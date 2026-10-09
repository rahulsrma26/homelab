#!/usr/bin/env bats
# Checks after `labber setup` ran in a fresh container treated as a VM: an admin user
# with sudo, Docker, everything set up for that user. Runs inside that container, as
# root, started by run-setup.sh — not on its own.

setup() { log=/root/setup1.log; }

tty_run() {
    local input="$1"; shift
    local cmd; printf -v cmd '%q ' "$@"
    run script -qefc "$cmd" /dev/null <<< "$input"
    output=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -d '\r')
}

@test "setup ran every step without a failure" {
    cat "$log"
    grep -q 'setup summary' "$log"
    grep -q '✓ done: ' "$log"
    ! grep -q 'failed: ' "$log" || false
    [ -z "$(ls -d /tmp/labber-files-* 2>/dev/null)" ]
    # the Proxmox side of the guest agent is printed for the host
    grep -q 'qm set <VMID> --agent enabled=1' "$log"
}

@test "admin user: in sudo and docker, owns the services folder" {
    id -nG admin | grep -qw sudo
    id -nG admin | grep -qw docker
    [ "$(stat -c %U /opt/homelab/services)" = admin ]
    grep -qx 'admin=admin' /var/lib/labber/setup.state
}

@test "SSH: key-only, the key is the admin's, root login off (VM)" {
    grep -qx 'PermitRootLogin no' /etc/ssh/sshd_config.d/10-labber.conf
    grep -qx 'PasswordAuthentication no' /etc/ssh/sshd_config.d/10-labber.conf
    /usr/sbin/sshd -t
    grep -q 'labber-setup-test' /home/admin/.ssh/authorized_keys
    [ "$(stat -c '%U %a' /home/admin/.ssh/authorized_keys)" = "admin 600" ]
}

@test "Docker runs, with log rotation; the admin can use it" {
    systemctl is-active --quiet docker
    grep -q '"max-size": "10m"' /etc/docker/daemon.json
    runuser -u admin -- docker info >/dev/null
    runuser -u admin -- docker compose version >/dev/null
}

@test "guest agent installed; the VM gets a reboot check" {
    dpkg -s qemu-guest-agent >/dev/null
    grep -qE '^labber_reboot_required [01]$' /var/lib/labber/metrics/labber.prom
}

@test "Alloy: VM config plus container metrics and logs, running as root" {
    systemctl is-active --quiet alloy
    curl -fs localhost:12345/-/ready
    c=/etc/alloy/config.alloy
    grep -q 'replacement  = "vm"' "$c"
    grep -q 'set_collectors = \["cpu", ' "$c"
    grep -q 'prometheus.exporter.cadvisor "docker"' "$c"
    grep -q 'loki.source.docker "containers"' "$c"
    grep -qx 'User=root' /etc/systemd/system/alloy.service.d/labber.conf
    ! grep -q '@[A-Z_]*@' "$c" || false
}

@test "labber for the admin: installed, shell function, daily update check" {
    [ "$(readlink /usr/local/bin/labber)" = /usr/local/lib/labber/labber ]
    grep -qx '# labber shell function' /home/admin/.bashrc
    grep -qx '# labber completion' /home/admin/.zshrc
    systemctl is-enabled --quiet labber-check-updates.timer
    grep -qx 'User=admin' /etc/systemd/system/labber-check-updates.service
    run runuser -u admin -- labber ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"no services installed"* ]]
}

@test "zsh with powerlevel10k is the admin's shell; fzf works in it" {
    [ "$(getent passwd admin | cut -d: -f7)" = "$(command -v zsh)" ]
    head -1 /home/admin/.zshrc | grep -qx '# labber zsh'
    [ "$(stat -c %U /home/admin/.zshrc)" = admin ]
    [ -f /home/admin/.p10k.zsh ] && [ "$(stat -c %U /home/admin/.p10k.zsh)" = admin ]
    [ -x /home/admin/.fzf/bin/fzf ]
    grep -q 'fzf' /home/admin/.zshrc
    # root's shell is left alone on a VM
    [ "$(getent passwd root | cut -d: -f7)" = /bin/bash ]
}

@test "fail2ban guards SSH" {
    fail2ban-client status sshd
}

@test "second run, as the admin through sudo: nothing left to do" {
    # setup re-runs itself under sudo when started as a normal user (test-only sudoers:
    # the real admin types a password here)
    echo 'admin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/labber-setup-test
    # answers: treat as VM? Enter (keeps vm) · Docker? Enter (keeps yes) · quit
    tty_run $'\n\nq\n' runuser -l admin -c 'labber setup'
    rm -f /etc/sudoers.d/labber-setup-test
    echo "$output"
    [[ "$output" == *"(last answer: vm)"* ]]
    [[ "$output" == *", VM, user: admin"* ]]
    # time sync can't work in a container; swap and NFS are optional
    todo=$(grep -E '^ +[0-9]+ \[' <<< "$output" | grep -v -E 'system update|time sync|swap|NFS' | grep -c ' todo' || true)
    [ "$todo" -eq 0 ]
}
