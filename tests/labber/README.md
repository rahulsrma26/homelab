# labber tests

Two layers, both written with [bats](https://bats-core.readthedocs.io/).

| Layer | File | Runs where | Time |
|---|---|---|---|
| Unit | `unit.bats` | throwaway Debian container on your machine (needs only Docker) | ~10 s |
| Integration | `integration.bats`, `commands.bats` | a test VM over SSH, against real Docker | ~4 min |

Both test the **working tree**, including uncommitted changes.

## Unit tests

```bash
make test-labber-unit
# or, to run a subset:
tests/labber/run-unit.sh -f placeholder
```

Covers the logic without Docker or network: labber's files (`@NAME@` filling, finding `files/`, download + install, the forwarder), `.env` templates (`{{ name }}`, `default()`, `generate()`) and parsing, compose-config parsing, service-name checks, data-folder ownership, `.bashrc` blocks, update-status cache, and the generated `ifupdown`/`netplan` static-IP configs (never applied). It then checks `labber/files/alloy/*.alloy`, and the VM, LXC and Docker-host configs `setup` generates from them, with the real `alloy` binary.

## Setup in a fresh container

```bash
make test-labber-setup                  # both paths, a few minutes; needs Docker and internet
tests/labber/run-setup.sh lxc           # or one of them
tests/labber/run-setup.sh vm
```

`run-setup.sh` starts a fresh Debian container with systemd as PID 1 and runs `labber setup` the way it runs on a new machine: piped (`bash <(…) setup`, so it downloads its own files), as root, answering every question. Each run starts from scratch, so no VM snapshot or Proxmox access is needed.

| Path | Answers | Checked by |
|---|---|---|
| **lxc** — like a Proxmox LXC (also a container on the host's kernel) | not a VM, no Docker, every step ticked | `setup-lxc.bats`: everything for root, SSH root by key, lean LXC Alloy config, second run finds nothing to do |
| **vm** — treated as a VM | VM, Docker; an `admin` user exists beforehand, as the Debian installer creates one | `setup-vm.bats`: admin in sudo + docker groups and owning the services folder, root SSH off, nested Docker with log rotation, Alloy with container metrics (as root), labber/zsh/p10k/fzf for the admin, guest agent, and a second run **as the admin through `sudo labber setup`** finds nothing to do |

A container can't cover time sync, swap/zram, the guest agent talking to Proxmox, or static IPs; the VM tests below do.

## Integration tests

```bash
LABBER_TEST_HOST=user@vm LABBER_TEST_KEY=~/.ssh/key make test-labber-vm
# also test static-IP moves and the automatic rollback (disconnects SSH for a few minutes):
LABBER_TEST_HOST=user@vm LABBER_TEST_KEY=~/.ssh/key make test-labber-vm NETWORK=<spare-ip>
```

`run-vm.sh` copies a git snapshot of the working tree (respecting `.gitignore`, so no `.env` files) plus the `fixtures/labber-test` service to `/tmp/labber-test` on the VM, and runs labber there with:

| Variable | Points labber at |
|---|---|
| `LABBER_REPO` | the snapshot, instead of GitHub |
| `LABBER_URL` | a tarball of the labber under test (like GitHub's), instead of GitHub |
| `LABBER_SERVICE_BASE` | a scratch folder, instead of `/opt/homelab/services` |

So real services on the VM are never touched. The tests run in order:

- `integration.bats` — the service lifecycle: install, ls, stop/start, port conflict, unset values, rebuild, check-updates, update, uninstall; then a re-run of `labber setup` must find nothing to do.
- `commands.bats` — everything else: status, restart, logs, shell, reinstall, deploy (alias and picker), rollback of a failed rebuild and of a failed update (images and files), update of a service missing from the repo, labber self-install and self-update, the upgrade from a pre-4.0 labber through the forwarder, `go`, tab completion, `tool`, the menu, uninstall (keeping the folder, and of a service whose compose file is broken), and `clean`.

Both suites install the labber under test on the VM (`/usr/local/lib/labber`, linked from `/usr/local/bin/labber`). `commands.bats` also checks the upgrade from the last pre-4.0 labber (taken from git history): its `labber update` installs the forwarder at `services/labber`, which moves to the new layout on its next run. Its `clean` test prunes **all** unused Docker data on the VM.

**VM requirements:** Debian, already through `labber setup` (Docker, the user in the `docker` group), and passwordless sudo for the test user:

```bash
echo "<user> ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/labber-test
```

Only use a throwaway VM. Snapshot it after setup so you can roll back if a test run leaves it in a bad state.

## Fixture

`fixtures/labber-test/` is a tiny service (busybox) built to exercise labber: `.env` templates (generated, typed, defaulted, and one name used twice), a published port, a bind-mount data folder with `PUID`/`PGID`, a locally built image, and a one-shot container that exits 0. It lives here, not in `services/`, so it never shows up in deploy lists.

## CI

`.github/workflows/ci.yml` runs on every push and pull request: the unit tests and the fresh-container setup tests above (both paths, in parallel), the monitoring tests, shellcheck (`tests/repo/shellcheck.sh`, pinned version) and the repo lint (`tests/repo/lint.sh`): `.env.example` templates well-formed with known generators and no old-style placeholders, every compose `${VAR}` without a default in `.env.example`, no private IPs, no `.env` files. Run the same locally with `make ci`. The VM tests need the test VM and stay manual.
