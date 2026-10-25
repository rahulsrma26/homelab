"""Validate public service templates and run isolated application smoke tests."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from forgejo import check_forgejo
from garage import check_garage
from forgejo_s3 import check_forgejo_s3
from vaultwarden import check_vaultwarden
from ntfy import check_ntfy


TEMPLATE = re.compile(
    r"\{\{\s*([a-z_][a-z0-9_]*)\s*"
    r"(?:\|\s*(default|generate|choice)\((.*?)\)\s*)?\}\}"
)


def fill(match):
    name, function, argument = match.groups()
    if function == "default":
        return argument
    if function == "choice":
        return argument.split(",")[0].strip()
    if function == "generate":
        if argument == "uuid":
            return "00000000-0000-4000-8000-000000000001"
        if argument.startswith("hex"):
            return "a" * int(argument[3:])
        if argument.startswith("base64_"):
            import base64

            return base64.b64encode(b"a" * int(argument[7:])).decode()
        return "a" * int(argument.rsplit(",", 1)[1])
    if name.endswith("_port"):
        return "8088"
    if name.endswith("_id"):
        return "-1001"
    if name.endswith("_ip"):
        return "192.0.2.10"
    return "audit.example.org"


def run(args, **kwargs):
    try:
        return subprocess.check_output(args, text=True, **kwargs)
    except subprocess.CalledProcessError as error:
        # Show validator diagnostics, without dumping environment arguments.
        print(error.output, file=sys.stderr)
        raise SystemExit("service validation failed") from None


def reclaim(root):
    """Containers running as root (Authelia) write into mounted test folders; hand
    them back to this user so the temporary directory can be removed."""
    subprocess.run(["docker", "run", "--rm", "--network", "none", "-v", f"{root}:/work", "labber-unit",
                    "chown", "-R", f"{os.getuid()}:{os.getgid()}", "/work"],
                   check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main(repo):
    with tempfile.TemporaryDirectory(prefix="homelab-service-check-") as temporary:
        try:
            checks(repo, Path(temporary))
        finally:
            reclaim(temporary)


def checks(repo, root):
    paths = run(["git", "-C", str(repo), "ls-files", "-co", "--exclude-standard", "-z", "--", "services"]).split("\0")
    for relative in set(filter(None, paths)):
        source, target = repo / relative, root / relative
        if source.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    configurations = {}
    variants = {}
    count = 0
    for compose in sorted((root / "services").glob("*/docker-compose.yml")):
        directory = compose.parent
        example = directory / ".env.example"
        content = TEMPLATE.sub(fill, example.read_text()) if example.exists() else ""
        env_file = directory / ".env"
        env_file.write_text(content)
        env_file.chmod(0o600)
        environment = os.environ.copy()
        for line in content.splitlines():
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", line):
                environment.pop(line.split("=", 1)[0], None)
        for key in ("COMPOSE_FILE", "COMPOSE_PROFILES", "COMPOSE_PROJECT_NAME", "COMPOSE_ENV_FILES"):
            environment.pop(key, None)
        for variant in sorted(directory.glob("compose.*.yml")) or [None]:
            args = ["docker", "compose", "--project-directory", str(directory), "--env-file", str(env_file), "-f", str(compose)]
            if variant:
                args += ["-f", str(variant)]
            config = json.loads(run(args + ["config", "--format", "json"], env=environment))
            configurations[directory.name] = config
            variants.setdefault(directory.name, {})[variant.name.split(".")[1] if variant else ""] = config
            count += 1
            if directory.name == "monitoring":
                services = config["services"]
                assert not services["pve-exporter"].get("ports"), "exporter must stay private"
                assert not services["alertmanager"].get("ports"), "Alertmanager must stay private"
                assert "--web.enable-lifecycle" not in services["prometheus"]["command"]
                assert services["prometheus"].get("ports") and services["loki"].get("ports")
                assert services["grafana"]["environment"]["INFLUXDB_ADMIN_TOKEN"]
            if directory.name == "soulsync":
                active = run(args + ["config", "--services"], env=environment).splitlines()
                assert "slskd" not in active, "inactive profiles must not be expected by health checks"
                assert "slskd-vpn" in active
            if directory.name == "frigate":
                targets = {port["target"] for port in config["services"]["frigate"].get("ports", [])}
                assert 5000 not in targets, "Frigate's unauthenticated API must stay private"
                assert 8971 in targets, "Home Assistant needs Frigate's authenticated API"
    print(f"ok   {count} Compose configurations, monitoring/Frigate boundaries and active profiles")
    config = configurations["authelia"]["services"]["authelia"]
    args = ["docker", "run", "--rm", "--network", "none"]
    for key, value in config["environment"].items():
        args += ["-e", f"{key}={value}"]
    args += ["-v", f"{root / 'services/authelia/config/authelia'}:/config:ro", config["image"],
             "authelia", "config", "validate", "--config", "/config/configuration.yml"]
    print(run(args))
    print("ok   real Authelia validates its rendered configuration and environment")

    # Test the LDAP bind and storage/notifier startup too: schema validation
    # cannot detect an incorrect bind DN or a mismatched LDAP password.
    smoke = configurations["authelia"]
    smoke.pop("name", None)
    for service in smoke["services"].values():
        service.pop("ports", None)
        service.pop("container_name", None)
        service["restart"] = "no"
    for volume in smoke.get("volumes", {}).values():
        volume.pop("name", None)
    smoke["networks"] = {"default": {"internal": True}}
    config_path = root / "services/authelia/config/authelia/configuration.yml"
    # The disposable network has no internet access; NTP is unrelated to LDAP.
    with config_path.open("a") as config_file:
        config_file.write("\nntp:\n  disable_startup_check: true\n")
    smoke_file = root / "authelia-smoke.json"
    smoke_file.write_text(json.dumps(smoke))
    command = ["docker", "compose", "-p", f"homelab-auth-check-{os.getpid()}", "-f", str(smoke_file)]
    try:
        run(command + ["up", "-d", "--wait", "--wait-timeout", "90"], env=environment)
        run(command + ["exec", "-T", "authelia", "wget", "-qO-", "http://localhost:9091/api/health"], env=environment)
        print("ok   Authelia starts with real LLDAP and answers its health endpoint")
    except SystemExit:
        print(run(command + ["logs", "--no-color"], env=environment), file=sys.stderr)
        raise
    finally:
        run(command + ["down", "--volumes", "--remove-orphans"], env=environment)

    check_forgejo(variants["forgejo"]["local"], root, repo, environment, run)
    check_garage(configurations["garage"], root, environment, run)
    check_forgejo_s3(variants["forgejo"], configurations["garage"], root, environment, run)
    check_vaultwarden(configurations["vaultwarden"], root, environment, run)
    check_ntfy(configurations["ntfy"], root, environment, run)


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
