#!/usr/bin/env bash
# End-to-end test of scripts/smbmgr (install.sh + the smbmgr tool) in a Debian container
# with systemd (the image from tests/labber/setup). Needs only Docker (and internet:
# Samba is installed from Debian).
#   - install: hardened global config, smbd up, nmbd off, check green
#   - add: <share>-ro / <share>-rw with stored passwords; a folder on a read-only mount
#     gets no -rw user; nested shares; users stay in their own share
#   - personal accounts: password from stdin, never stored; rw/ro per share
#   - reset, remove (disable / --purge, personal accounts updated), user set/passwd/remove
#   - refusals: wrong password, anonymous, guest, SMB 2.1; SMB3 + AES; nothing on 139
#   - refusals: existing system accounts (never taken over or deleted), system folders,
#     user set without shares; per-command --help
#   - refresh (a mount turning writable / read-only), move (users and passwords stay)
#   - a failed self-test rolls back state, smb.conf and the users it created
#   - check spots disabled users and stale passwords; failed commands leave the state
#     unchanged; check spots hand edits and missing folders
#   - re-running install.sh keeps everything; allow blocks networks that aren't listed
#   - install.sh --uninstall removes only what it made
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
image=labber-setup-test c="smbmgr-test-$$"
trap 'docker rm -f "$c" >/dev/null 2>&1 || true' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }
# grep that reads all of its input: `… | grep -q` can fail under pipefail when grep
# quits early and the writer gets SIGPIPE (a flaky "not found")
has() { grep "$@" >/dev/null; }

docker build -q -t "$image" "$repo/tests/labber/setup" >/dev/null
docker run -d --name "$c" --hostname "$c" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock "$image" >/dev/null
docker cp "$repo/scripts/smbmgr" "$c:/smbmgr-src"
for _ in $(seq 30); do docker exec "$c" systemctl is-system-running 2>/dev/null | has -E "running|degraded" && break; sleep 1; done
x() { docker exec "$c" bash -c "$1"; }
x 'apt-get update -qq >/dev/null; mkdir -p /srv/st/files/docs /srv/st/files/inbox /srv/st/vault-src/photos /srv/st/vault
   echo photo > /srv/st/vault-src/photos/img1.jpg; chown 1000:1000 /srv/st/files/inbox
   mount --bind /srv/st/vault-src /srv/st/vault && mount -o remount,ro,bind /srv/st/vault'
ip=$(x "hostname -I | awk '{print \$1}'")      # the container's own address, allowed below

out=$(x "bash /smbmgr-src/install.sh --allow '$ip/32' --yes" 2>&1) || { echo "$out"; fail "install"; }
grep -q "all good" <<<"$out" || { echo "$out"; fail "install: check not green"; }
[[ "$(x 'systemctl is-active nmbd || true')" != active ]] || fail "nmbd running"
pass "install: Samba + smbmgr, check green, nmbd off"

x 'smbmgr add files /srv/st/files && smbmgr add docs /srv/st/files/docs && smbmgr add vault /srv/st/vault' >/dev/null \
    || fail "adding shares"
[[ "$(x "awk -F'\t' '{print \$1}' /etc/smbmgr/secrets | sort | paste -sd' ' -")" == "docs-ro docs-rw files-ro files-rw vault-ro" ]] \
    || fail "unexpected users (a read-only mount must get no -rw user)"
[[ "$(x 'stat -c %a /etc/smbmgr/secrets /etc/smbmgr | paste -sd" " -')" == "600 700" ]] || fail "secrets/state not root-only"
x 'smbmgr show files' | has -E 'files-rw +[A-Za-z0-9]{24}' || fail "show doesn't print the stored password"
pass "add: -ro/-rw per share, no -rw on a read-only mount, nested share, passwords stored root-only"

pw() { x "awk -F'\t' -v u='$1' '\$1 == u {print \$2}' /etc/smbmgr/secrets"; }
st() { docker exec "$c" smbclient "//127.0.0.1/$1" -U "$2%$3" -m SMB3 -c "$4" 2>&1 | grep -oE "NT_STATUS_[A-Z_]+" | head -1 || true; }
[[ -z "$(st files files-rw "$(pw files-rw)" 'put /etc/hostname t.txt')" ]] || fail "files-rw can't write"
[[ "$(st files files-ro "$(pw files-ro)" 'put /etc/hostname x.txt')" == NT_STATUS_ACCESS_DENIED ]] || fail "files-ro can write"
[[ -z "$(st files files-ro "$(pw files-ro)" 'get t.txt /tmp/t.txt')" ]] || fail "files-ro can't read"
[[ "$(st files docs-rw "$(pw docs-rw)" ls)" == NT_STATUS_ACCESS_DENIED ]] || fail "docs-rw got into files"
[[ "$(st docs files-rw "$(pw files-rw)" ls)" == NT_STATUS_ACCESS_DENIED ]] || fail "files-rw got into docs"
[[ "$(st vault vault-ro "$(pw vault-ro)" 'put /etc/hostname x.txt')" == NT_STATUS_ACCESS_DENIED ]] || fail "vault is writable"
[[ "$(x 'stat -c %u:%g /srv/st/files/t.txt')" == "0:0" ]] || fail "writes not owned by root"
[[ -z "$(st files files-rw "$(pw files-rw)" 'put /etc/hostname inbox/scan.pdf')" ]] || fail "can't write into inbox"
x 'setpriv --reuid=1000 --regid=1000 --clear-groups rm /srv/st/files/inbox/scan.pdf' || fail "uid 1000 can't delete from its inbox"
[[ -z "$(x 'find /srv/st -name ".smbmgr-check*"')" ]] || fail "the self-test left a file behind"
pass "access: -ro reads only, -rw writes, users stay in their own share; writes owned by root"

out=$(x "echo 'MySecretPassword123' | smbmgr user add me --rw files,docs --ro vault --password-stdin") || fail "user add"
grep -q "smb://me@$ip/\$" <<<"$out" && grep -q "vault: smb://me@$ip/vault" <<<"$out" || { echo "$out"; fail "user add: no smb:// address"; }
[[ "$(x "grep -c '^me	' /etc/smbmgr/secrets || true")" == 0 ]] || fail "personal password was stored"
[[ -z "$(st docs me MySecretPassword123 'put /etc/hostname me.txt')" ]] || fail "me can't write docs"
[[ "$(st vault me MySecretPassword123 'put /etc/hostname x')" == NT_STATUS_ACCESS_DENIED ]] || fail "me can write vault"
[[ -z "$(st vault me MySecretPassword123 ls)" ]] || fail "me can't read vault"
x "echo short | smbmgr user add me2 --rw files --password-stdin" >/dev/null 2>&1 && fail "accepted a short password"
x "echo 'MySecretPassword123' | smbmgr user add me2 --rw vault --password-stdin" >/dev/null 2>&1 && fail "accepted --rw on a read-only share"
pass "personal account: password not stored, rw/ro per share; bad input refused"

# Empty RW columns must stay empty, including when the last RW permission is removed.
x "echo 'MySecretPassword123' | smbmgr user add reader --ro files,docs --password-stdin" >/dev/null
[[ -z "$(st files reader MySecretPassword123 ls)" ]] || fail "read-only personal account can't read"
[[ "$(st files reader MySecretPassword123 'put /etc/hostname denied.txt')" == NT_STATUS_ACCESS_DENIED ]] || fail "read-only personal account can write"
x 'smbmgr user set reader --rw files --ro docs; smbmgr user set reader --ro files,docs' >/dev/null
[[ "$(st docs reader MySecretPassword123 'put /etc/hostname denied.txt')" == NT_STATUS_ACCESS_DENIED ]] || fail "RW to RO transition grants writes"
x 'smbmgr user list' | has -E '^reader +- +files,docs$' || fail "read-only permissions displayed in the RW column"
x 'smbmgr user remove reader --yes' >/dev/null
pass "read-only personal accounts stay read-only across creation and permission changes"

x 'useradd --system --no-create-home clash-ro; mkdir -p /srv/st/clash'
before=$(x 'md5sum /etc/smbmgr/* | md5sum')
x 'smbmgr add clash /srv/st/clash' >/dev/null 2>&1 && fail "took over an existing system account (clash-ro)"
x "echo 'MySecretPassword123' | smbmgr user add backup --ro files --password-stdin" >/dev/null 2>&1 && fail "took over the backup account"
x 'smbmgr user remove backup --yes' >/dev/null 2>&1 && fail "user remove accepted a system account"
x 'id backup >/dev/null && id clash-ro >/dev/null' || fail "a system account was deleted"
for p in / /etc /etc/smbmgr /var /root /proc; do
    x "smbmgr add sys $p" >/dev/null 2>&1 && fail "shared the system folder $p"
done
x 'smbmgr user set me' >/dev/null 2>&1 && fail "user set without shares accepted"
[[ "$(x 'md5sum /etc/smbmgr/* | md5sum')" == "$before" ]] || fail "a refused command changed the state"
x 'smbmgr add --help' | has 'smbmgr add <name> <path>' || fail "add --help"
uh=$(x 'smbmgr user --help'); grep -q 'smbmgr user passwd <name>' <<<"$uh" && ! grep -q 'smbmgr add' <<<"$uh" || fail "user --help"
pass "refused: existing system accounts (kept), system folders, user set without shares; --help per command"

before=$(x 'md5sum /etc/smbmgr/* | md5sum')
x 'mkdir -p "/srv/st/100%done" "/srv/st/trail " /srv/st/g; groupadd -r grp-ro'
refused() {   # refused <what> <command>: fails with an error message, not silently
    local o; o=$(x "$2" 2>&1) && fail "accepted: $1"
    grep -q "error:" <<<"$o" || { echo "$o"; fail "no error message: $1"; }
}
refused "a reserved share name" 'smbmgr add global /srv/st/g'
refused "a path with %" 'smbmgr add pct "/srv/st/100%done"'
refused "a path with a trailing space" 'smbmgr add trail "/srv/st/trail "'
refused "an existing group's name" 'smbmgr add grp /srv/st/g'
refused "--rw without shares" "echo MySecretPassword123 | smbmgr user add me3 --rw --password-stdin"
refused "extra arguments" 'smbmgr add two /srv/st/g extra'
refused "two shares to remove" 'smbmgr remove files docs'
refused "a bad IPv4" 'smbmgr allow "300.1.1.1/24"'
refused "a bad prefix" 'smbmgr allow "198.51.100.0/33"'
refused "a comma list" 'smbmgr allow "198.51.100.0/24,203.0.113.0/24"'
refused "a password prompt without a terminal" 'setsid smbmgr user add me3 --rw files </dev/null'
[[ "$(x 'md5sum /etc/smbmgr/* | md5sum')" == "$before" ]] || fail "a refused command changed the state"
x "echo 'MySecretPassword123' | smbmgr user add dup --rw files,files, --password-stdin" >/dev/null || fail "user add with a repeated share"
[[ "$(x 'smbmgr user list' | awk '$1 == "dup" {print $2}')" == files ]] || fail "share list not cleaned up"
x 'smbmgr user remove dup --yes' >/dev/null
x 'install -m 600 /etc/hostname /srv/st/files/private.txt'
[[ -z "$(st files files-ro "$(pw files-ro)" 'get private.txt /tmp/p.txt')" ]] || fail "-ro can't read a 600 file"
[[ "$(x 'smbmgr show files-rw' | awk '{print $2}')" == "$(pw files-rw)" ]] || fail "show <user>"
pass "refused (with a message): reserved names, % / trailing-space paths, groups, bad flags and CIDRs; -ro reads any file"

x 'mount -o remount,rw,bind /srv/st/vault'
chk=$(x 'smbmgr check' 2>&1 || true)
grep -q "vault is writable now" <<<"$chk" || fail "check missed a read-only mount turning writable"
x 'smbmgr refresh' >/dev/null || fail "refresh"
[[ -z "$(st vault vault-rw "$(pw vault-rw)" 'put /etc/hostname r.txt')" ]] || fail "vault-rw can't write after refresh"
[[ "$(st vault me MySecretPassword123 'put /etc/hostname x')" == NT_STATUS_ACCESS_DENIED ]] || fail "me (read-only on vault) can write after refresh"
x 'rm -f /srv/st/vault-src/r.txt; mount -o remount,ro,bind /srv/st/vault'
x 'smbmgr refresh vault' >/dev/null || fail "refresh back to read-only"
[[ "$(x "pdbedit -Lw | grep '^vault-rw:' | cut -d: -f5")" == *D* ]] || fail "vault-rw not disabled on a read-only mount"
x 'smbmgr check' >/dev/null 2>&1 || fail "check not green after refresh"
x 'mkdir -p /srv/st/docs2'; old=$(pw docs-rw)
x 'smbmgr move docs /srv/st/docs2' >/dev/null || fail "move"
[[ "$(pw docs-rw)" == "$old" && -z "$(st docs docs-rw "$old" 'put /etc/hostname m.txt')" ]] || fail "docs-rw after move"
x 'test -f /srv/st/docs2/m.txt' || fail "move: writes don't land in the new folder"
pass "refresh: -rw added / disabled as the mount changes; move keeps users and passwords"

# a folder the owner (nobody, for this test) can't write: the self-test fails
x 'mkdir -p /srv/st/locked; smbmgr owner nobody >/dev/null'
before=$(x 'md5sum /etc/smbmgr/* | md5sum')
out=$(x 'smbmgr add locked /srv/st/locked' 2>&1) && fail "add succeeded although locked-rw can't write"
grep -q "rolled back" <<<"$out" && grep -q "writable for nobody" <<<"$out" || { echo "$out"; fail "no rollback message / hint"; }
[[ "$(x 'md5sum /etc/smbmgr/* | md5sum')" == "$before" ]] || fail "rollback: state changed"
x 'grep -q "^\[locked\]" /etc/samba/smb.conf' && fail "rollback: share still in smb.conf"
x 'id locked-ro' >/dev/null 2>&1 && fail "rollback: locked-ro still exists"
x 'smbmgr owner root' >/dev/null
x 'smbmgr check' >/dev/null 2>&1 || fail "check not green after a rollback"
pass "a failed self-test rolls back the state, smb.conf and the new users"

[[ "$(st files files-rw wrong ls)" == NT_STATUS_LOGON_FAILURE ]] || fail "wrong password accepted"
[[ "$(docker exec "$c" smbclient -L //127.0.0.1 -N 2>&1 | grep -oE 'NT_STATUS_[A-Z_]+' | head -1)" == NT_STATUS_ACCESS_DENIED ]] || fail "anonymous listing allowed"
[[ -n "$(st files guest '' ls)" ]] || fail "guest access allowed"
[[ -n "$(docker exec "$c" smbclient //127.0.0.1/files -U "files-rw%$(pw files-rw)" -m SMB2_10 -c ls 2>&1 | grep -oE 'NT_STATUS_[A-Z_]+' || true)" ]] \
    || fail "SMB 2.1 accepted"
x "( (sleep 5; echo exit) | smbclient //127.0.0.1/files -U files-rw%$(pw files-rw) >/dev/null 2>&1 & ); sleep 2; smbstatus -b" | has "SMB3.*AES" \
    || fail "session not SMB3 + AES-encrypted"
if x 'ss -ltn | grep -q ":139 "'; then fail "something listens on 139"; fi
pass "refused: wrong password, anonymous, guest, SMB 2.1; SMB3 + AES; nothing on 139"

old=$(pw docs-rw)
x 'smbmgr reset docs-rw' >/dev/null
[[ "$(st docs docs-rw "$old" ls)" == NT_STATUS_LOGON_FAILURE && -z "$(st docs docs-rw "$(pw docs-rw)" ls)" ]] || fail "reset"
x 'smbmgr remove docs' >/dev/null
[[ "$(x "pdbedit -Lw | grep '^docs-ro:' | cut -d: -f5")" == *D* ]] || fail "removed share's users not disabled"
x 'smbmgr user list' | grep -E '^me ' | has docs && fail "me still lists the removed share"
x 'smbmgr list' | has "disabled users of removed shares: docs-ro docs-rw" || fail "list doesn't show the removed share's users"
x 'smbmgr remove docs --purge' >/dev/null || fail "purging a removed share's users"
x 'id docs-ro' >/dev/null 2>&1 && fail "leftover docs-ro not deleted"
x 'smbmgr remove vault --purge' >/dev/null
[[ "$(x "pdbedit -L | grep -c '^vault-' || true")" == 0 && "$(x "grep -c '^vault-' /etc/smbmgr/secrets || true")" == 0 ]] || fail "--purge left users or secrets"
x "echo 'AnotherPassword4567' | smbmgr user passwd me --password-stdin" >/dev/null
[[ -z "$(st files me AnotherPassword4567 ls)" && "$(st files me MySecretPassword123 ls)" == NT_STATUS_LOGON_FAILURE ]] || fail "user passwd"
x 'smbmgr user remove me' >/dev/null; [[ "$(st files me AnotherPassword4567 ls)" == NT_STATUS_LOGON_FAILURE ]] || fail "user remove"
pass "reset, remove (disable / --purge, personal account updated), user passwd/remove"

x 'smbpasswd -d files-ro >/dev/null'
chk=$(x 'smbmgr check' 2>&1 || true)
grep -q "files-ro: it's disabled" <<<"$chk" || { echo "$chk"; fail "check missed a disabled user"; }
x 'printf "Different12345\nDifferent12345\n" | smbpasswd -s files-ro >/dev/null; smbpasswd -e files-ro >/dev/null'
chk=$(x 'smbmgr check' 2>&1 || true)
grep -q "files-ro can't log in with its stored password" <<<"$chk" || { echo "$chk"; fail "check missed a stale password"; }
x 'smbmgr reset files-ro' >/dev/null && x 'smbmgr check' >/dev/null || fail "check not green after reset"
pass "check: spots disabled users and stale passwords; reset fixes them"

before=$(x 'md5sum /etc/smbmgr/* | md5sum')
x 'smbmgr add files /srv/st/files' >/dev/null 2>&1 && fail "duplicate share accepted"
x 'smbmgr add x /nope' >/dev/null 2>&1 && fail "missing folder accepted"
[[ "$(x 'md5sum /etc/smbmgr/* | md5sum')" == "$before" ]] || fail "a failed command changed the state"
x 'echo "# hand edit" >> /etc/samba/smb.conf'
chk=$(x 'smbmgr check' 2>&1 || true)      # check exits non-zero here, as it should
grep -q "differs from the state" <<<"$chk" || fail "check missed a hand edit"
x 'smbmgr apply' >/dev/null; x 'smbmgr check' >/dev/null || fail "check not green after apply"
pass "failed commands leave the state alone; check spots hand edits; apply repairs"

x "bash /smbmgr-src/install.sh --yes" >/dev/null 2>&1 || fail "re-running install"
[[ "$(x 'smbmgr list' | grep -c '^files ')" == 1 && -z "$(st files files-rw "$(pw files-rw)" ls)" ]] || fail "re-install lost state"
x "smbmgr allow 198.51.100.0/24" >/dev/null       # a documentation range: not ours
if docker exec "$c" smbclient "//$ip/files" -U "files-rw%$(pw files-rw)" -m SMB3 -c ls 2>&1 | has 't\.txt'; then
    fail "allow didn't block a network that isn't listed"
fi
[[ -z "$(st files files-rw "$(pw files-rw)" ls)" ]] || fail "localhost blocked by allow"
pass "re-install keeps everything; allow blocks unlisted networks, localhost still works"

x 'bash /smbmgr-src/install.sh --uninstall' >/dev/null 2>&1 && fail "--uninstall without a terminal or --yes went ahead"
x 'bash /smbmgr-src/install.sh --uninstall --yes' >/dev/null 2>&1 || fail "--uninstall"
for t in 'command -v smbmgr' 'test -e /etc/smbmgr' 'id files-ro' 'id vault-ro' 'dpkg -s samba'; do
    x "$t" >/dev/null 2>&1 && fail "--uninstall left: $t"
done
x 'id backup >/dev/null && id clash-ro >/dev/null && test -f /srv/st/files/t.txt' || fail "--uninstall removed something it didn't make"
pass "--uninstall removes Samba, smbmgr and its users; folders and other accounts stay"
echo "all smbmgr tests passed"
