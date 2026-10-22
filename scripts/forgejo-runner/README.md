# forgejo-runner — a native Forgejo Actions runner

**Run it** as root on a Debian machine with Docker (e.g. a CI VM set up with `labber setup`, Docker yes):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rahulsrma26/homelab/refs/heads/main/scripts/forgejo-runner/install.sh)
```

First get a UUID and token from Forgejo: **Settings → Actions → Runners → Create new runner** (in a repository, your user settings or the site administration, depending on who should use the runner). The script asks for the Forgejo URL, the UUID and the token (typed hidden), registers the runner and starts it.

**Why native, not in a container:** jobs with the `host` label run directly on the machine, so the checkout paths exist on the Docker host (tests that bind-mount files from the checkout work), and the machine's tools are used (`make`, `python3`, `git`, Docker). The runner has its own user, `forgejo-runner`, in the `docker` group. That is root-equivalent on the machine, not a sandbox: use it only for trusted repositories, on a machine that holds nothing else.

| Command | Does |
|---|---|
| `install.sh` | installs or updates the binary (latest release), the user, the folders and the systemd unit; asks to register the first time |
| `install.sh --register` | (re-)registers: Forgejo URL, UUID, token; rewrites the config |
| `install.sh --version X.Y.Z` | installs that version instead of the latest |
| `install.sh --status` | version, service state, registration, labels, the last log lines |
| `install.sh --dry-run` | what a run would do; changes nothing |
| `install.sh --uninstall` | removes the runner, its user, config and work folder (then remove it in Forgejo too) |

Flags for `--register`: `--url`, `--uuid`, `--labels` (default `labber-ci:host`), `--capacity` (default 1: no overlapping jobs). The token is never a flag (it would land in the shell history): it's asked hidden, or read from `FORGEJO_RUNNER_TOKEN`.

**What it sets up:**
- **Packages:** `git` and `nodejs` (JavaScript actions such as `actions/checkout` run on the host). Whatever your jobs call besides (e.g. `make`, `python3`) you install yourself.
- **Binary:** `/usr/local/bin/forgejo-runner`, from code.forgejo.org's releases, checked against the release's SHA-256 before it replaces anything.
- **Config:** `/etc/forgejo-runner/config.yml` (mode 600, holds the token). Written on `--register`; updates keep it.
- **Work folder:** `/var/lib/forgejo-runner/work` (checkouts; disposable).
- **Service:** `forgejo-runner.service`, started once the runner is registered; re-runs restart it.

**Updating:** run it again. It installs the latest release (or `--version`), rewrites the unit, restarts the runner, and keeps the registration. Check Forgejo's release notes first for breaking changes.
