#!/usr/bin/env bash
# End-to-end test of scripts/samba-setup.sh in a Debian container with systemd (the image
# from tests/labber/setup). Needs only Docker (and internet: the script installs Samba).
#   - shares files/media read-write, vault read-only; writes owned by the forced owner
#   - wrong password, anonymous listing and guests are refused; SMB below 3 is refused
#   - sessions are encrypted (SMB3, AES); nmbd is off and nothing listens on 139
#   - a re-run keeps the password and backs up smb.conf; --allow blocks other networks
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
image=labber-setup-test c="samba-test-$$"
trap 'docker rm -f "$c" >/dev/null 2>&1 || true' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

docker build -q -t "$image" "$repo/tests/labber/setup" >/dev/null
docker run -d --name "$c" --hostname "$c" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock "$image" >/dev/null
docker cp "$repo/scripts/samba-setup.sh" "$c:/samba-setup.sh"
for _ in $(seq 30); do docker exec "$c" systemctl is-system-running 2>/dev/null | grep -qE "running|degraded" && break; sleep 1; done
x() { docker exec "$c" bash -c "$1"; }
x 'apt-get update -qq >/dev/null; mkdir -p /srv/st/files/inbox /srv/st/media /srv/st/vault/photos
   echo photo > /srv/st/vault/photos/img1.jpg; chown 1000:1000 /srv/st/files/inbox'

pw='TestPassword1234567890ab'
ip=$(x "hostname -I | awk '{print \$1}'")      # the container's own address, allowed below
setup="bash /samba-setup.sh --user smbtest --share files=/srv/st/files --share media=/srv/st/media --share vault=/srv/st/vault:ro --yes"
out=$(x "$setup --password $pw --allow '$ip/32'" 2>&1) || { echo "$out"; fail "setup"; }
grep -q "login works" <<<"$out" || fail "setup didn't confirm a login"
pass "setup: smb.conf passes testparm, smbd up, login works"

smb() { docker exec "$c" smbclient "$@" 2>&1 || true; }
status() { grep -oE "NT_STATUS_[A-Z_]+" | head -1; }
[[ "$(smb //127.0.0.1/files -U "smbtest%wrong" -c ls | status)" == NT_STATUS_LOGON_FAILURE ]] || fail "wrong password accepted"
[[ "$(smb -L //127.0.0.1 -N | status)" == NT_STATUS_ACCESS_DENIED ]] || fail "anonymous listing allowed"
[[ -n "$(smb //127.0.0.1/files -U "guest%" -c ls | status)" ]] || fail "guest access allowed"
[[ -n "$(smb //127.0.0.1/files -U "smbtest%$pw" -m SMB2_10 -c ls | status)" ]] || fail "SMB 2.1 accepted (minimum should be SMB3)"
pass "refused: wrong password, anonymous, guest, SMB below 3"

smb //127.0.0.1/files -U "smbtest%$pw" -c "put /etc/hostname t.txt; put /etc/hostname inbox/scan.pdf" >/dev/null
smb //127.0.0.1/media -U "smbtest%$pw" -c "put /etc/hostname m.txt" >/dev/null
[[ "$(x 'stat -c %u:%g /srv/st/files/t.txt /srv/st/files/inbox/scan.pdf /srv/st/media/m.txt | sort -u')" == "0:0" ]] || fail "writes not owned by the forced owner (root)"
[[ "$(smb //127.0.0.1/vault -U "smbtest%$pw" -c "put /etc/hostname x.txt" | status)" == NT_STATUS_ACCESS_DENIED ]] || fail "vault is writable"
smb //127.0.0.1/vault -U "smbtest%$pw" -c "cd photos; get img1.jpg /tmp/i.jpg" >/dev/null
[[ "$(x 'cat /tmp/i.jpg')" == photo ]] || fail "vault not readable"
x 'setpriv --reuid=1000 --regid=1000 --clear-groups rm /srv/st/files/inbox/scan.pdf' || fail "uid 1000 can't delete from its inbox"
pass "files/media writable (owned by root), vault read-only, inbox owner can delete"

x "( (sleep 5; echo exit) | smbclient //127.0.0.1/files -U smbtest%$pw >/dev/null 2>&1 & ); sleep 2; smbstatus -b" | grep -q "SMB3.*AES" || fail "session not SMB3 + AES-encrypted"
[[ "$(x 'systemctl is-active nmbd || true')" != active ]] || fail "nmbd running"
x 'ss -ltn | grep -q ":139 "' && fail "something listens on 139"
pass "session SMB3 + AES encryption; nmbd off; nothing on 139"

out=$(x "$setup --allow '$ip/32'" 2>&1)
grep -q "password unchanged" <<<"$out" || fail "re-run changed the password"
smb //127.0.0.1/files -U "smbtest%$pw" -c ls | grep -q "t.txt" || fail "old password doesn't work after re-run"
[[ "$(x 'ls /etc/samba/ | grep -c bak')" -ge 1 ]] || fail "no smb.conf backup"
pass "re-run: password kept, smb.conf backed up"

x "$setup --allow '198.51.100.0/24'" >/dev/null 2>&1     # a documentation range: not ours
if smb "//$ip/files" -U "smbtest%$pw" -c ls | grep -q 't\.txt'; then fail "--allow didn't block a network that isn't listed"; fi
smb //127.0.0.1/files -U "smbtest%$pw" -c ls | grep -q "t.txt" || fail "localhost blocked by --allow"
pass "--allow: unlisted network refused, localhost still works"
echo "all Samba tests passed"
