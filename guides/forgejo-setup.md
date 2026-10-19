# Forgejo and labber CI/CD

Forgejo is the main Git host; selected public repositories are published to GitHub.
Private repositories stay local. Forgejo runs checks and dispatches deployments;
**labber sets up guests and manages Compose services**.

## One VM or two guests?

**One Debian VM can run Forgejo, Docker and its native runner**, including this
repo's full CI suite. Forgejo does not require an LXC plus a VM.

| Layout | Starting resources | Boundary |
|---|---|---|
| Combined VM on primary | 4 vCPU, 8 GB RAM, 100 GB SSD | Fewest guests. Trusted workflows with Docker access control the entire VM, including Forgejo's repositories, database and credentials. CI load affects Git hosting. |
| Forgejo LXC on primary + runner VM on secondary | Server: 2 cores, 2 GB, 32 GB; runner: 4 vCPU, 8 GB, 80 GB | Git data stays separate from disposable CI execution. Recommended when adding collaborators or more experimental workloads. |
| Forgejo LXC alone | 2 cores, 2 GB, 32 GB | Git hosting works; a runner is still needed for CI/CD. Run the privileged labber test suite in a VM. |

These are initial budgets, to adjust after measuring. Important private Git data
belongs on primary's ECC/redundant storage. Keep the combined VM or server LXC in
PBS. The runner's checkouts and Docker image cache are disposable.

Only trusted repositories use the LAN runner. Public GitHub pull requests stay on
GitHub-hosted CI until reviewed. Runner labels schedule jobs; they do not isolate
jobs sharing a machine. Separate Unix users on a Docker host are not an isolation
boundary either.

## Create the guest

Follow [new-guest.md](new-guest.md) for guest IDs, encrypted storage and firewall
switches. Both layouts use the server VLAN.

For a **server-only LXC**, run on primary with your chosen values:

```bash
pct create <ID> local:vztmpl/debian-13-standard_<ver>_amd64.tar.zst \
  --hostname forgejo --cores 2 --memory 2048 --swap 512 \
  --rootfs enc-nvme:32,mountoptions=noatime\;discard \
  --net0 name=eth0,bridge=vmbr0,tag=<server-vid>,firewall=1,ip=dhcp \
  --unprivileged 1 --features nesting=1 --onboot 1
pct start <ID>
pct enter <ID>
```

For a **combined or runner VM**, create a Debian 13 VM: q35, OVMF, CPU `host`,
VirtIO SCSI single with discard, QEMU guest agent, and a server-VLAN NIC. Create an
admin account during Debian installation. No hypervisor SSH/API credentials or GPU
are needed for Compose CI.

Inside each guest, at its console as root:

```bash
apt update && apt install -y curl
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/labber/labber) setup
```

Choose Docker **yes** and configure Alloy's monitoring URLs. LXCs use root; VMs use
the admin account set up by labber. Log back in for Docker group membership.

## Install the server

On the combined VM or server LXC:

```bash
labber forgejo install
cd /opt/homelab/services/forgejo
docker compose ps
```

`.env` asks for the data UID/GID (defaults 1000), `FORGEJO_DATA` (default `./data`;
point it at a host dataset bind-mounted into the guest to keep repositories in
snapshots and replication), HTTP port 3002, SSH port 2222,
`FORGEJO_DOMAIN` (the HTTPS name), `FORGEJO_SSH_HOST` (the guest's direct hostname
or address), and `TRAEFIK_IP` (the proxy's source IP, never `*`). SQLite and all
persistent application state are in `FORGEJO_DATA`. The server has no Docker socket.

The installer and open registration are disabled. Create the first administrator:

```bash
docker compose exec --user git forgejo forgejo \
  --config /data/gitea/conf/app.ini admin user create \
  --username <admin-name> --email <admin-email> \
  --admin --random-password --must-change-password
```

Save the printed password, sign in over HTTPS, change it, and enable 2FA. Add other
accounts through the admin UI. Repositories default to private.

### Storage for artifacts and packages

`forgejo_storage` picks where Actions artifacts and packages go (Actions logs always
stay in `FORGEJO_DATA`):

- **`local`**: in `FORGEJO_DATA`, so they share its backups.
- **`s3`**: an S3 bucket, e.g. [`services/garage`](../services/garage/) (`s3_endpoint`
  as `host:3900`, the bucket's access and secret key from Garage's `.env`). Use it for
  data you can rebuild: the bucket has no backup of its own.

Forgejo **refuses to start while its S3 storage is unreachable**. A running Forgejo keeps
serving Git and the web UI without it (packages and artifacts fail), and after a restart
it retries until the bucket is back. Run the S3 server on the same host as Forgejo; to
start without it, switch `COMPOSE_FILE` in `.env` to `compose.local.yml` and restart
(packages and artifacts are missing until you switch back).

Packages are off unless `forgejo_packages_enabled` is `true`; artifacts are kept 7 days
and logs 90 (`forgejo_artifact_retention_days`, `forgejo_log_retention_days`).

## DNS, proxy and firewall

The HTTPS name `git.<domain>` resolves to Traefik. The separate SSH hostname
resolves directly to Forgejo: Traefik's guest does not listen on Forgejo's SSH
port. Add these entries alongside the existing installed Traefik routes:

```yaml
http:
  routers:
    forgejo:
      rule: Host(`git.<domain>`)
      entryPoints: [websecure]
      service: forgejo
      middlewares: [secure-headers]
  services:
    forgejo:
      loadBalancer:
        servers:
          - url: http://192.168.server.forgejo:3002
```

Use Forgejo's login for its web UI, Git, API, runners and packages. Browser-only
forward-auth in front of every URL breaks non-browser clients. The runner must
trust Traefik's certificate; retain TLS verification.

- Allow HTTP 3002 from Traefik. Block direct home/guest/IoT access before the broad
  home-to-server allowance. Allow Git SSH 2222 only from intended Git clients.
- Guest administration uses the existing port 22 management policy, separately
  from Git SSH. Runners poll Forgejo over HTTPS and need no inbound runner port.
- Allow runner outbound DNS/HTTPS for Git, images and packages. Deployment needs
  SSH only to selected service guests. Do not add general management-VLAN access.
- Use LAN/Tailscale; no internet inbound ports. When moving between combined and
  split layouts, update DNS, firewall and the direct SSH hostname together.

## Native runner on the VM

On the combined VM, the `runner/` templates are in the installed Forgejo directory.
For a separate VM, copy that directory from a trusted checkout first. Run these
commands with `runner/` in the current directory:

```bash
sudo apt update
sudo apt install -y git make python3 nodejs curl ca-certificates openssh-client
docker info
docker compose version

# Extract the Linux binary from the official multi-arch image.
docker pull data.forgejo.org/forgejo/runner:13.2.0
runner_image=$(docker create data.forgejo.org/forgejo/runner:13.2.0)
runner_tmp=$(mktemp -d)
docker cp "$runner_image:/bin/forgejo-runner" "$runner_tmp/forgejo-runner"
docker rm -v "$runner_image"
sudo install -m 755 "$runner_tmp/forgejo-runner" /usr/local/bin/forgejo-runner
rm -rf "$runner_tmp"
forgejo-runner --version

# Create the dedicated user only on the first installation.
sudo useradd --system --create-home --home-dir /var/lib/forgejo-runner \
  --shell /bin/bash forgejo-runner
sudo usermod -aG docker forgejo-runner
sudo install -d -m 700 -o forgejo-runner -g forgejo-runner /etc/forgejo-runner
sudo install -d -m 700 -o forgejo-runner -g forgejo-runner /var/lib/forgejo-runner/work
sudo install -m 600 -o forgejo-runner -g forgejo-runner \
  runner/config.yml.example /etc/forgejo-runner/config.yml
sudo install -m 644 runner/forgejo-runner.service /etc/systemd/system/forgejo-runner.service
```

In the repository, open **Settings → Actions → Runners → Create new runner**.
Register at repository scope. Edit `/etc/forgejo-runner/config.yml` with `sudoedit`:
replace the HTTPS URL, UUID and token using the UI's values. Retain mode 600 and
ownership by `forgejo-runner`. Add explicit connections for other trusted repos.

```bash
sudo -u forgejo-runner docker info
sudo systemctl daemon-reload
sudo systemctl enable --now forgejo-runner
sudo journalctl -u forgejo-runner -n 50 --no-pager
```

Check the runner is online with label `labber-ci`. Native execution keeps checkout
paths on the Docker host, so this repo's bind-mounted test fixtures work. Capacity
1 prevents overlapping jobs using shared test image tags. Docker membership grants
root-equivalent control of the VM; the separate user is not a sandbox.

The native runner is upgraded separately from the server: stop its systemd service,
repeat binary extraction with the chosen supported runner version, then restart.
Do not reinstall the config template over registration credentials during updates.

## CI and stable branches

Enable Actions in repository settings. Copy `examples/ci.yml` to
`.forgejo/workflows/ci.yml` in the local homelab repo. It runs existing check targets
on pushes, then the full guest/Samba/UPS suite on `dev` and manual runs. These
privileged tests execute inside the runner VM, never on the hypervisor.

`test-services` includes application startup, so it is slower than static Compose
validation. The example reuses current targets; a future Compose-only target can
provide earlier feedback. Cached images help; fresh guest package installation
still takes time and needs network access.

Protect `main`, require both `checks` and `integration` to pass for the exact commit
being promoted, and keep `dev → main` fast-forward only. This example supplies the
checks without a promotion credential; configure local promotion after confirming
the status names in your instance. GitHub becomes a published copy with Forgejo
as its sole writer. Do not keep two independent promotion jobs advancing it.
Forgejo's GitHub-style job `permissions` are not equivalent to GitHub's; scope
runner registration and credentials explicitly.

## CD through labber

Copy `examples/deploy.yml` to `.forgejo/workflows/deploy.yml` in a **private deployment
repository**. It is manually triggered from `main`, takes no arbitrary shell or
service input, and runs `labber homepage update` over SSH. Copy/review it for each
chosen service. **Traefik stays manually managed and is excluded from CD.**

Register a repository-scoped `labber-deploy:host` runner using the native setup.
On a single VM you can add this label and that repository's connection to the same
runner only when all its CI authors are trusted with deployment access. Labels and
separate users do not protect deployment credentials from privileged CI jobs on
the same VM. Use another VM when those trust levels need separation.

Create a key dedicated to the target, and set Actions secrets `DEPLOY_HOST`,
`DEPLOY_USER`, `DEPLOY_SSH_KEY` and `DEPLOY_KNOWN_HOSTS`. Verify the host-key line
against the guest console; do not blindly trust network discovery. Restrict the
public key in the target service owner's `authorized_keys`:

```text
from="<deployment-runner-ip>",restrict,command="/usr/local/bin/labber homepage update" <deployment-public-key>
```

Use the existing root account in an LXC or service-owning admin in a VM. The target
already needs complete `.env` values and permission to run labber without interactive
sudo. A conflict needing input fails for manual review. Target Docker access still
controls that guest. Do not deploy Forgejo or its runner from a job they execute.

**Set the target's source before enabling CD.** As the service owner, configure a
read-only Forgejo deploy key and verified SSH host key, then save the source:

```bash
labber source set 'ssh://git@<forgejo-ssh-host>:2222/<owner>/<repo>.git' main
labber source show
labber ls --remote
```

The example deploys the target's configured branch as it exists at execution time;
the workflow SHA is not automatically forwarded by SSH. Pin the host's source to
a reviewed full commit SHA if a fixed revision is needed, and update that pin
deliberately. Commands, self-updates and the daily timer all use the saved source.
Authenticate as that target user, not the CI runner. Labber also supports local
working trees for tests without committing/pushing; see
[repository sources](../labber/README.md#repository-sources-and-local-testing).
Keep the `services/`, `tools/` and `labber/` layout in a private site repo if it is
used as the host-wide source. CI/CD uses labber; no second service manager is needed.

## Publishing, backups and recovery

Keep public templates/scripts and private inventory in separate repositories.
Configure push mirroring only on public-safe repositories, with branch filter
`main`. Mirroring publishes history as well as files. Private repositories have no
GitHub mirror. Credentials stay in Actions secrets or protected target `.env` files,
even for private repositories.

Back up **all of `FORGEJO_DATA` plus `.env`**: repositories, SQLite, application config and
keys, accounts, packages (in `local` mode) and Actions credentials belong together.
In `s3` mode, artifacts and packages are only in the bucket. GitHub is not a
backup of the private forge. Keep the guest in PBS; for a consistent independent
copy, stop its runner and Forgejo, copy that complete state to protected backup
storage, then restart both. Include off-site coverage for irreplaceable private
repositories. A backup writable by the CI VM is not sufficient protection from CI.

Take a restorable backup before `labber forgejo update`. A database migration may
require restoring the matched config/data backup rather than only an older image.
Runner caches can be rebuilt; protect runner tokens or re-register after recovery.
Keep a local template checkout and backup recovery instructions available without
Forgejo. Add its HTTPS endpoint to Uptime Kuma. Verify authenticated push/pull,
runner pickup, a failing job and CD against a disposable guest before important apps.

References: [server installation](https://forgejo.org/docs/v15.0/admin/installation/docker/),
[runner registration](https://forgejo.org/docs/v15.0/admin/actions/registration/),
[native runner](https://forgejo.org/docs/v15.0/admin/actions/installation/binary/),
[runner security](https://forgejo.org/docs/v15.0/admin/actions/security/),
[Actions differences](https://forgejo.org/docs/v15.0/user/actions/github-actions/),
[push mirrors](https://forgejo.org/docs/v15.0/user/repo-mirror/).
