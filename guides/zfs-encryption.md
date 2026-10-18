# ZFS encryption unlocked by Tang

ZFS native encryption for a Proxmox host's guest and data storage, unlocked automatically at boot by two Tang servers through Clevis (Shamir 1-of-2), with a passphrase for emergencies. The design and threat model are in [architecture/encryption.md](../architecture/encryption.md); setting up the Tang servers is [tang-server.md](tang-server.md).

Tested on Proxmox 9.2 / OpenZFS 2.4. Run everything as root.

**What you end up with, per host:**

| Copy of the key | Where | Used for |
|---|---|---|
| wrapped by both Tangs (`/root/.zfs-key-clevis`) | on the host | the normal unlock at every boot |
| passphrase-encrypted (`/root/.zfs-key-passphrase-backup`) | on the host | the emergency unlock when no Tang answers |
| the raw key (base64) + the passphrase | your password manager | recovery after losing both boot disks |

**Before starting:** two Tang servers answering (`curl -s http://<tang>/adv`), and an unencrypted place for the Tailscale LXC (`local-zfs`) so the emergency unlock works remotely.

## 1. Encrypted datasets and the Clevis binding (every host)

One **random 32-byte raw key** per server, shared by all of that server's encrypted datasets: e.g. `rpool/encrypted` for VM/LXC disks on NVMe and `<datapool>/encrypted` for data. Run as root.

```bash
apt install -y clevis jose curl
curl -s http://<tang-a-ip>/adv | head -c 40; echo
curl -s http://<tang-b-ip>/adv | head -c 40; echo
```

### 1. Key (in RAM only) and datasets

```bash
umask 077
head -c 32 /dev/urandom > /dev/shm/zfs-key-raw      # /dev/shm = RAM; /tmp is on rpool (disk)
for ds in rpool/encrypted <datapool>/encrypted; do
  zfs create -o encryption=aes-256-gcm -o keyformat=raw -o keylocation=file:///dev/shm/zfs-key-raw "$ds"
  zfs set keylocation=prompt "$ds"    # REQUIRED: the Clevis pipe only works with "prompt"
done
zfs get -o name,property,value encryption,keyformat,keylocation,keystatus rpool/encrypted <datapool>/encrypted
```

ZFS can't encrypt existing data in place. On a pool that already holds data, create `<pool>/encrypted` next to it and move guests over: VM → Hardware → disk → **Move Disk** to the encrypted storage.

### 2. Off-host copy of the raw key

```bash
base64 < /dev/shm/zfs-key-raw
```

Save it in your password manager as **"<host> ZFS raw key (base64)"**. It's the only copy that survives losing both boot disks.

**It's now on your screen in the clear:** do this on the console or a plain SSH session, not in a web terminal that records sessions, and clear the scrollback afterwards (`clear && printf '\033[3J'`, plus your terminal's own scrollback).

### 3. Wrap the key with both Tangs (SSS 1-of-2)

```bash
clevis encrypt sss '{"t":1,"pins":{"tang":[{"url":"http://<tang-a-ip>"},{"url":"http://<tang-b-ip>"}]}}' \
  < /dev/shm/zfs-key-raw > /root/.zfs-key-clevis
chmod 600 /root/.zfs-key-clevis
```

It asks you to trust each Tang's key. Compare the thumbprints with `tang-show-keys` on each board before answering `y`.

### 4. Emergency passphrase copy

Use a **long** passphrase (5–6 random words or 16+ characters): the file sits on the unencrypted root, so someone who takes the host can try passphrases offline.

```bash
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -in /dev/shm/zfs-key-raw -out /root/.zfs-key-passphrase-backup
chmod 600 /root/.zfs-key-passphrase-backup
```

Save the passphrase in your password manager.

### 5. Test the Clevis unlock, then remove the plain key

```bash
for ds in rpool/encrypted <datapool>/encrypted; do
  zfs unmount "$ds"; zfs unload-key "$ds"
  clevis decrypt < /root/.zfs-key-clevis | zfs load-key "$ds"
done
zfs mount -a
zfs get -o name,property,value keystatus,mounted rpool/encrypted <datapool>/encrypted   # available / yes

shred -u /dev/shm/zfs-key-raw    # only after the test passed AND the base64 copy is saved
```

### 6. Proxmox storages

```bash
pvesm add zfspool enc-nvme --pool rpool/encrypted --content images,rootdir --sparse 1
pvesm add zfspool enc-sata --pool <datapool>/encrypted --content images,rootdir --sparse 1
```

Keep `local-zfs` (unencrypted) for the Tailscale LXC only ([tailscale-lxc.md](tailscale-lxc.md)).

---

## 2. Unlock at boot (every host)

### Unlock script — `/usr/local/bin/zfs-unlock.sh`

```bash
cat > /usr/local/bin/zfs-unlock.sh <<'EOF'
#!/bin/bash
# Unlock this host's encrypted datasets via Clevis/Tang (SSS 1-of-2).
DATASETS="rpool/encrypted <datapool>/encrypted"
CLEVIS_KEY=/root/.zfs-key-clevis
MAX_RETRIES=30
RETRY_INTERVAL=5
log() { echo "$(date '+%F %T') $1" >> /var/log/zfs-unlock.log; logger -t zfs-unlock "$1"; echo "$1"; }

[ -f "$CLEVIS_KEY" ] || { log "ERROR: no $CLEVIS_KEY"; exit 1; }
for ds in $DATASETS; do
    if [ "$(zfs get -H -o value keystatus "$ds")" = available ]; then log "$ds already unlocked"; continue; fi
    for i in $(seq 1 $MAX_RETRIES); do
        if clevis decrypt < "$CLEVIS_KEY" 2>/dev/null | zfs load-key "$ds" 2>/dev/null; then
            log "$ds unlocked via Tang (attempt $i/$MAX_RETRIES)"; break
        fi
        if [ "$i" -eq "$MAX_RETRIES" ]; then
            log "FAILED to unlock $ds after $MAX_RETRIES attempts. Run: zfs-emergency-unlock.sh"; exit 1
        fi
        sleep "$RETRY_INTERVAL"
    done
done
EOF
chmod 755 /usr/local/bin/zfs-unlock.sh
```

The first attempt usually fails while the network is still coming up; the retry a few seconds later succeeds. No fixed `sleep` is needed.

### systemd service

```bash
cat > /etc/systemd/system/zfs-unlock.service <<'EOF'
[Unit]
Description=ZFS Clevis/Tang auto-unlock
After=network-online.target networking.service zfs-import.target
Wants=network-online.target
Before=pve-guests.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=600
ExecStart=/usr/local/bin/zfs-unlock.sh
ExecStart=/usr/sbin/zfs mount -a

[Install]
WantedBy=multi-user.target
WantedBy=pve-guests.service
EOF
systemctl daemon-reload
systemctl enable zfs-unlock.service
```

**`WantedBy`, not `RequiredBy=pve-guests.service`.** With `RequiredBy`, a failed unlock stops **all** guests, including the unencrypted Tailscale LXC needed to fix it remotely. With `WantedBy`, encrypted guests simply fail to start: ZFS can't mount a locked dataset, so nothing gets written into an empty folder.

### Emergency unlock — `/usr/local/bin/zfs-emergency-unlock.sh`

Asks for the passphrase once and unlocks every dataset.

```bash
cat > /usr/local/bin/zfs-emergency-unlock.sh <<'EOF'
#!/bin/bash
# Manual unlock with the backup passphrase (when no Tang is reachable).
DATASETS="rpool/encrypted <datapool>/encrypted"
BACKUP=/root/.zfs-key-passphrase-backup
ITER=600000            # must match the -iter used to create $BACKUP (openssl's default is 10000)
umask 077
key=/dev/shm/zfs-key-emergency
openssl enc -aes-256-cbc -pbkdf2 -iter "$ITER" -d -in "$BACKUP" -out "$key" || { echo "FAILED: wrong passphrase?"; rm -f "$key"; exit 1; }
for ds in $DATASETS; do
    [ "$(zfs get -H -o value keystatus "$ds")" = available ] && { echo "$ds already unlocked"; continue; }
    zfs load-key -L "file://$key" "$ds" && echo "$ds unlocked"
done
shred -u "$key"
zfs mount -a && echo "Mounted. Start guests with: systemctl restart zfs-unlock.service && systemctl start pve-guests.service"
EOF
chmod 700 /usr/local/bin/zfs-emergency-unlock.sh
```

### Change the passphrase or iterations

E.g. a backup file created without `-iter`:

```bash
umask 077
clevis decrypt < /root/.zfs-key-clevis > /dev/shm/k
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -in /dev/shm/k -out /root/.zfs-key-passphrase-backup.new
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in /root/.zfs-key-passphrase-backup.new | cmp - /dev/shm/k && echo MATCH
# only after MATCH:
mv /root/.zfs-key-passphrase-backup.new /root/.zfs-key-passphrase-backup
# set ITER=600000 in zfs-emergency-unlock.sh
shred -u /dev/shm/k
```

---

## 3. Tests (every host, once)

| # | Before rebooting the server | Expect |
|---|---|---|
| T1 | nothing | unlocked via Tang within seconds |
| T2 | Tang A stopped (`sudo systemctl stop tangd.socket` on it) | unlocked via Tang B |
| T3 | Tang B stopped | unlocked via Tang A |
| T4 | both stopped | service fails after ~3 min → `zfs-emergency-unlock.sh` unlocks; the Tailscale LXC is up, so this also works remotely |

Start the Tangs again after T2–T4 (`sudo systemctl start tangd.socket`). Other clients are unaffected while a Tang is stopped; they only ask at boot. Check after each boot:

```bash
journalctl -u zfs-unlock.service -b --no-pager | tail -5
zfs get -H -o name,property,value keystatus,mounted rpool/encrypted <datapool>/encrypted
```

---

## 4. Re-bind a host (key rotation or a Tang address change)

```bash
# 1. Rotation only: generate new keys on the Tang (old keys stay active)
/usr/libexec/tangd-keygen /var/lib/tang/

# 2. Re-bind EVERY client while the old keys/IPs still work. On each client:
umask 077
clevis decrypt < /root/.zfs-key-clevis > /dev/shm/zfs-key-temp
clevis encrypt sss \
    '{"t":1,"pins":{"tang":[{"url":"http://<tang-a-ip>"},{"url":"http://<tang-b-ip>"}]}}' \
    < /dev/shm/zfs-key-temp > /root/.zfs-key-clevis-new
clevis decrypt < /root/.zfs-key-clevis-new | cmp - /dev/shm/zfs-key-temp && echo "OK"
mv /root/.zfs-key-clevis-new /root/.zfs-key-clevis
shred -u /dev/shm/zfs-key-temp

# 3. Rotation only: after all clients are re-bound, disable the old keys on the Tang
cd /var/lib/tang/
mv OLD_KEY_FILE .OLD_KEY_FILE   # prefix with . to disable

# 4. Back up the new keys. Wait a week. Then delete the old ones.
```

Re-binding doesn't change the ZFS key, so the saved raw key and the passphrase file stay valid.

---

## Troubleshooting

### Boot unlock retrying in logs

```bash
journalctl -u zfs-unlock.service -b
cat /var/log/zfs-unlock.log
curl -s http://<tang-a-ip>/adv | head -c 80    # Tang reachable?
curl -s http://<tang-b-ip>/adv | head -c 80
clevis decrypt < /root/.zfs-key-clevis | wc -c  # must print 32
zfs get keylocation rpool/encrypted <datapool>/encrypted   # must be 'prompt' (most common issue)
```

### "Device busy" when unloading a key

```bash
zfs unmount <ds>; zfs unload-key <ds>
fuser -mv /<ds>; lsof +D /<ds>     # what's holding it
```

### Unlocked but guests not running

```bash
zfs get mounted -r rpool/encrypted <datapool>/encrypted   # mounted=no → zfs mount -a
systemctl start pve-guests.service                         # start the guests that failed at boot
```

---

## Quick reference

```bash
zfs get keystatus,encryption -r rpool/encrypted <datapool>/encrypted   # status
systemctl status zfs-unlock.service; cat /var/log/zfs-unlock.log
/usr/local/bin/zfs-emergency-unlock.sh                                  # manual unlock
zfs unmount <ds> && zfs unload-key <ds>                                 # lock (testing)

# Files
# /root/.zfs-key-clevis              Clevis-wrapped key (needs a Tang)
# /root/.zfs-key-passphrase-backup   passphrase-wrapped key (emergency)
# password manager                   raw key (base64) + passphrase
# keylocation                        MUST be 'prompt'
```

---

## Limits

1. ZFS metadata (dataset names, sizes) is not encrypted — use non-descriptive names
2. Replicating an encrypted dataset: **non-raw**, the receiver stores it under its own encryption and can read it; **raw** (`zfs send -w`, or TrueNAS with dataset properties included), it stays locked with the source's key. See [architecture/backups.md](../architecture/backups.md)
3. Live migration between hosts doesn't work with encrypted storage (each host has its own key)
4. Proxmox labels ZFS encryption "experimental" — vzdump backups work fine when key is loaded
5. Performance overhead is minimal with AES-NI (OpenZFS 2.4.1 includes AVX2 AES-GCM improvements)
