#!/usr/bin/env bats
# Checks after `labber setup` ran in a fresh container (the LXC path: root only, no
# Docker). Runs inside that container, as root, started by run-setup.sh — not on its own.

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
    # run piped, it downloaded its own files to a temp folder and removed it afterwards
    [ -z "$(ls -d /tmp/labber-files-* 2>/dev/null)" ]
}

@test "a second run finds nothing left to do" {
    # answers: treat as VM? Enter (keeps lxc) · Docker? Enter (keeps no) · quit
    tty_run $'\n\nq\n' labber setup
    echo "$output"
    [[ "$output" == *"(last answer: lxc)"* ]]
    [[ "$output" == *", LXC, user: root"* ]]
    todo=$(grep -E '^ +[0-9]+ \[' <<< "$output" | grep -v -E 'system update' | grep -c ' todo' || true)
    [ "$todo" -eq 0 ]
}

@test "labber is installed as a folder, linked, with shell function and completion" {
    [ "$(readlink /usr/local/bin/labber)" = /usr/local/lib/labber/labber ]
    [ -f /usr/local/lib/labber/files/alloy/base.alloy ]
    grep -qx '# labber shell function' /root/.bashrc
    grep -qx '# labber completion' /root/.zshrc
    [ -d /opt/homelab/services ]
}

@test "SSH: key-only, root by key (LXC)" {
    grep -qx 'PermitRootLogin prohibit-password' /etc/ssh/sshd_config.d/10-labber.conf
    grep -qx 'PasswordAuthentication no' /etc/ssh/sshd_config.d/10-labber.conf
    /usr/sbin/sshd -t
    grep -q 'labber-setup-test' /root/.ssh/authorized_keys
}

@test "locale, automatic updates, journal limit" {
    grep -qx 'LANG=en_US.UTF-8' /etc/default/locale
    grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades
    grep -q 'SystemMaxUse=200M' /etc/systemd/journald.conf.d/10-labber.conf
}

@test "health check: timer on, metrics written, no reboot flag in an LXC" {
    systemctl is-enabled --quiet labber-health-check.timer
    f=/var/lib/labber/metrics/labber.prom
    grep -qx 'labber_reboot_required 0' "$f"
    grep -qE '^labber_security_updates_pending [0-9]+$' "$f"
    [ -x /etc/update-motd.d/95-labber-health ]
    grep -q '/opt/homelab/services/.labber-updates' /usr/local/sbin/labber-health-check
}

@test "Alloy: running with the lean LXC config" {
    systemctl is-active --quiet alloy
    curl -fs localhost:12345/-/ready
    c=/etc/alloy/config.alloy
    grep -q 'managed by labber setup' "$c"
    grep -q 'set_collectors = \["stat", "filesystem", "systemd", "textfile"\]' "$c"
    grep -q 'replacement  = "lxc"' "$c"
    grep -q 'url = "http://127.0.0.1:9090/api/v1/write"' "$c"
    ! grep -q '@[A-Z_]*@' "$c" || false
    ! grep -q 'cadvisor' "$c" || false                 # not a Docker host
}

@test "zsh with powerlevel10k is root's shell; fzf works in it" {
    [ "$(getent passwd root | cut -d: -f7)" = "$(command -v zsh)" ]
    head -1 /root/.zshrc | grep -qx '# labber zsh'
    [ -f /root/.p10k.zsh ]
    [ -d /root/.zsh/powerlevel10k ]
    [ -x /root/.fzf/bin/fzf ]
    grep -q 'fzf' /root/.zshrc
}

@test "fail2ban guards SSH" {
    fail2ban-client status sshd
}

@test "network left alone (choice 3), remembered" {
    grep -qx 'network_choice=3' /var/lib/labber/setup.state
}
