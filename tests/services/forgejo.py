"""Exercise a fresh private forge, authenticated Git and a real Actions runner."""

import base64
import json
import os
import secrets
import shutil
import subprocess
import time


def check_forgejo(config, root, repo, environment, run):
    model = json.loads(json.dumps(config))
    model.pop("name", None)
    service = model["services"]["forgejo"]
    settings = service["environment"]
    assert settings["FORGEJO__security__INSTALL_LOCK"] == "true"
    assert settings["FORGEJO__service__DISABLE_REGISTRATION"] == "true"
    assert settings["FORGEJO__service__REQUIRE_SIGNIN_VIEW"] == "true"
    assert settings["FORGEJO__repository__DEFAULT_PRIVATE"] == "private"
    assert settings["FORGEJO__security__REVERSE_PROXY_TRUSTED_PROXIES"] != "*"
    assert all(mount.get("source") != "/var/run/docker.sock" for mount in service["volumes"])
    # No host ports, real DNS, external users, or public notification destinations.
    service.pop("ports", None)
    service.pop("container_name", None)
    service["restart"] = "no"
    settings["FORGEJO__server__ROOT_URL"] = "http://forgejo:3000/"
    settings["FORGEJO__server__DOMAIN"] = "forgejo"
    model["networks"] = {"default": {"internal": True}}
    # A named volume works identically on Linux and Docker Desktop and lets the
    # image initialize ownership without changing files in the source checkout.
    service["volumes"] = [{"type": "volume", "source": "data", "target": "/data"}]
    model["volumes"] = {"data": {}}
    config_path = root / "forgejo-smoke.json"
    config_path.write_text(json.dumps(model))
    command = ["docker", "compose", "-p", f"homelab-forgejo-check-{os.getpid()}", "-f", str(config_path)]
    runner_name = f"homelab-forgejo-runner-{os.getpid()}"
    password = secrets.token_hex(24)
    secret = secrets.token_hex(20)
    auth = base64.b64encode(f"audit:{password}".encode()).decode()

    def forge(*arguments):
        return run(command + ["exec", "-T", "--user", "git", "forgejo", "forgejo",
                              "--config", "/data/gitea/conf/app.ini", *arguments], env=environment)

    def client(*arguments):
        return run(["docker", "run", "--rm", "--network", network,
                    "-v", f"{root}:/work", "labber-unit", *arguments])

    def api(path, payload=None):
        args = ["curl", "-fsS", "-H", f"Authorization: Basic {auth}",
                "-H", "Content-Type: application/json"]
        if payload is not None:
            args += ["-d", json.dumps(payload)]
        return json.loads(client(*args, f"http://forgejo:3000/api/v1/{path}"))

    try:
        run(command + ["up", "-d", "--wait", "--wait-timeout", "90"], env=environment)
        cid = run(command + ["ps", "-q", "forgejo"], env=environment).strip()
        networks = json.loads(run(["docker", "inspect", "--format", "{{json .NetworkSettings.Networks}}", cid]))
        network = next(iter(networks))
        health = json.loads(client("curl", "-fsS", "http://forgejo:3000/api/healthz"))
        assert health["status"] == "pass"
        # The documented first-admin command supports random passwords and
        # mandatory rotation; the test uses a temporary known password for Git.
        help_text = forge("admin", "user", "create", "--help")
        assert "--random-password" in help_text and "--must-change-password" in help_text
        forge("admin", "user", "create", "--username", "audit", "--email", "audit@example.org",
              "--password", password, "--admin", "--must-change-password=false")
        repository = api("user/repos", {"name": "checks", "private": True, "auto_init": False})
        assert repository["private"]
        status = int(client("curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
                            "http://forgejo:3000/api/v1/repos/audit/checks").strip())
        assert status in (401, 403, 404), f"private repository was accessible anonymously: {status}"

        runner_uuid = forge("forgejo-cli", "actions", "register", "--name", "smoke",
                            "--scope", "audit/checks", "--secret", secret).strip().splitlines()[-1]
        runner_config = (repo / "services/forgejo/runner/config.yml.example").read_text()
        runner_config = runner_config.replace("<forgejo-https-url>", "http://forgejo:3000/")
        runner_config = runner_config.replace("<runner-uuid>", runner_uuid).replace("<runner-token>", secret)
        runner_config = runner_config.replace("/var/lib/forgejo-runner/work", "/tmp/forgejo-smoke-work")
        runner_file = root / "runner-smoke.yml"
        runner_file.write_text(runner_config)
        runner_file.chmod(0o644)  # disposable credentials, readable by the image's UID 1000
        run(["docker", "run", "-d", "--name", runner_name, "--network", network,
             "-v", f"{runner_file}:/runner.yml:ro", "data.forgejo.org/forgejo/runner:13.2.0",
             "forgejo-runner", "daemon", "--config", "/runner.yml"])
        fixture = root / "fixture"
        workflows = fixture / ".forgejo/workflows"
        workflows.mkdir(parents=True)
        (workflows / "smoke.yml").write_text(
            "name: smoke\non: [push]\njobs:\n  pass:\n    runs-on: labber-ci\n"
            "    steps:\n      - run: echo 'native runner picked up this commit'\n"
        )
        shutil.copytree(repo / "labber", fixture / "labber")
        probe = fixture / "tools/source-probe"
        probe.mkdir(parents=True)
        (probe / "install.sh").write_text("#!/bin/bash\necho forgejo-source-ok\n")
        sample = fixture / "services/source-probe"
        sample.mkdir(parents=True)
        (sample / "README.txt").write_text("private Forgejo source fixture\n")
        client("bash", "-euc", """
git config --global --add safe.directory /work/fixture
cd /work/fixture
git init -q -b main
git add .
git -c user.name=audit -c user.email=audit@example.org commit -qm smoke
git -c "http.extraHeader=Authorization: Basic $1" push -q http://forgejo:3000/audit/checks.git main
""", "_", auth)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            runs = api("repos/audit/checks/actions/runs").get("workflow_runs", [])
            if runs and runs[0]["status"] in ("completed", "success", "failure"):
                assert (runs[0].get("conclusion") or runs[0]["status"]) == "success", runs[0]
                break
            time.sleep(2)
        else:
            raise AssertionError("Forgejo runner did not complete the pushed workflow")
        print("ok   Forgejo starts privately; authenticated Git push triggers a real native runner", flush=True)
        # Use Git's usual authentication configuration, never credentials in the
        # source URL. Both labber's CLI and its self-update/assets fetch must use
        # this private Forgejo source rather than the default GitHub archive.
        print(client("env", "GIT_CONFIG_COUNT=1", "GIT_CONFIG_KEY_0=http.extraHeader",
                     f"GIT_CONFIG_VALUE_0=Authorization: Basic {auth}", "bash", "-euc", '''
script=/work/fixture/labber/labber
url=http://forgejo:3000/audit/checks.git
bash "$script" --source "$url" --ref main tool source-probe | grep -q forgejo-source-ok
source "$script"
source_resolve "$url" main
tmp=$(mktemp -d)
dir=$(labber_download "$tmp")
cmp "$dir/labber" "$script"
test -f "$dir/files/health-check.sh"
rm -rf "$tmp"
echo 'ok   labber fetches tools, script and setup assets from authenticated private Forgejo'
'''), end="")
        # Both shipped examples are parsed by the same runner, without executing
        # repository tests or attempting any SSH deployment.
        for filename in ("ci.yml", "deploy.yml"):
            output = run(["docker", "run", "--rm", "--network", "none",
                          "-v", f"{repo / 'services/forgejo/examples'}:/examples:ro",
                          "data.forgejo.org/forgejo/runner:13.2.0", "forgejo-runner", "exec",
                          "--list", "-W", f"/examples/{filename}", "-E", "workflow_dispatch"])
            expected = "deploy" if filename == "deploy.yml" else "checks"
            assert expected in output, output
        print("ok   real Forgejo runner parses the CI and labber CD examples", flush=True)
        (root / "forgejo-deploy.yml").write_text((repo / "services/forgejo/examples/deploy.yml").read_text())
        (root / "runner.service").write_text((repo / "services/forgejo/runner/forgejo-runner.service").read_text())
        print(client("python3", "-c", '''
import configparser, json, os, pathlib, subprocess, tempfile, yaml
source = pathlib.Path("/work/forgejo-deploy.yml")
workflow = yaml.safe_load(source.read_text())
body = workflow["jobs"]["deploy"]["steps"][0]["run"]
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    ssh = root / "ssh"
    ssh.write_text("#!/usr/bin/env python3\\nimport json, os, sys\\nopen(os.environ['SSH_TRACE'], 'w').write(json.dumps(sys.argv[1:]))\\nsys.exit(int(os.environ['SSH_EXIT']))\\n")
    ssh.chmod(0o755)
    environment = dict(os.environ, PATH=str(root) + ":" + os.environ["PATH"],
        DEPLOY_HOST="192.0.2.20", DEPLOY_USER="deploy", DEPLOY_SSH_KEY="disposable-key",
        DEPLOY_KNOWN_HOSTS="disposable-host-key", SSH_TRACE=str(root / "trace"))
    for code in (0, 17):
        environment["SSH_EXIT"] = str(code)
        result = subprocess.run(["bash", "-c", body], env=environment)
        assert result.returncode == code
        args = json.loads((root / "trace").read_text())
        assert args[-1] == "labber homepage update"
        assert args[-2] == "192.0.2.20"
        assert "StrictHostKeyChecking=yes" in args
        assert not pathlib.Path(args[args.index("-i") + 1]).exists()
print("ok   CD calls only the selected labber service, propagates failure and cleans credentials")
unit = configparser.ConfigParser(interpolation=None)
unit.read("/work/runner.service")
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    root.chmod(0o755)
    previous = os.umask(int(unit["Service"]["UMask"], 8))
    try:
        (root / "checkout").mkdir()
        path = root / "checkout/rules.yml"
        path.write_text("readable by a non-root test image")
        subprocess.run(["setpriv", "--reuid=65534", "--regid=65534", "--clear-groups", "cat", str(path)], check=True, stdout=subprocess.DEVNULL)
    finally:
        os.umask(previous)
print("ok   runner-created checkout files are readable by non-root test containers")
'''), end="")
    except BaseException:
        print(run(command + ["logs", "--no-color", "--tail", "50"], env=environment))
        result = subprocess.run(["docker", "logs", "--tail", "50", runner_name], capture_output=True, text=True)
        print(result.stdout + result.stderr)
        raise
    finally:
        subprocess.run(["docker", "rm", "-f", "-v", runner_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run(command + ["down", "--volumes", "--remove-orphans"], env=environment)
