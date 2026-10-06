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

Covers the logic without Docker or network: `.env` templates (`{{ name }}`, `default()`, `generate()`) and parsing, compose-config parsing, service-name checks, data-folder ownership, `.bashrc` blocks, update-status cache, and the generated `ifupdown`/`netplan` static-IP configs (never applied).

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
| `LABBER_URL` | the labber under test, instead of GitHub |
| `LABBER_SERVICE_BASE` | a scratch folder, instead of `/opt/homelab/services` |

So real services on the VM are never touched. The tests run in order:

- `integration.bats` — the service lifecycle: install, ls, stop/start, port conflict, unset values, rebuild, check-updates, update, uninstall; then a re-run of `labber setup` must find nothing to do.
- `commands.bats` — everything else: status, restart, logs, shell, reinstall, deploy (alias and picker), update of a service missing from the repo, labber self-install and self-update, `go`, tab completion, `tool`, the menu, uninstall keeping the folder, and `clean`.

`commands.bats` replaces `/usr/local/bin/labber` on the VM with the labber under test, and its `clean` test prunes **all** unused Docker data on the VM.

**VM requirements:** Debian, already through `labber setup` (Docker, the user in the `docker` group), and passwordless sudo for the test user:

```bash
echo "<user> ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/labber-test
```

Only use a throwaway VM. Snapshot it after setup so you can roll back if a test run leaves it in a bad state.

## Fixture

`fixtures/labber-test/` is a tiny service (busybox) built to exercise labber: `.env` templates (generated, typed, defaulted, and one name used twice), a published port, a bind-mount data folder with `PUID`/`PGID`, a locally built image, and a one-shot container that exits 0. It lives here, not in `services/`, so it never shows up in deploy lists.
