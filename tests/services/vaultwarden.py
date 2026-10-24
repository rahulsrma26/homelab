"""Run a real Vaultwarden: healthy as non-root, sign-ups and the admin page refused,
data kept across a restart, and no password in its logs."""

import json
import os


def check_vaultwarden(config, root, environment, run):
    model = json.loads(json.dumps(config))
    model.pop("name", None)
    service = model["services"]["vaultwarden"]
    settings = service["environment"]
    assert not service["image"].endswith(":latest"), "pin the Vaultwarden version"
    assert service.get("user") and not service["user"].startswith("0"), "Vaultwarden must not run as root"
    assert settings["SIGNUPS_ALLOWED"] == "false"
    assert settings["ADMIN_TOKEN"] == "", "the admin page is off unless a hash is set"
    assert {port["target"] for port in service.get("ports", [])} == {8080}

    service.pop("ports", None)
    service.pop("container_name", None)
    service["restart"] = "no"
    settings["DOMAIN"] = "http://vaultwarden:8080"
    model["networks"] = {"default": {"internal": True}}
    service["volumes"] = [{"type": "volume", "source": "data", "target": "/data"}]
    model["volumes"] = {"data": {}}
    # a named volume starts root-owned; hand it to the container's user first
    model["services"]["init"] = {"image": "labber-unit", "user": "0:0", "network_mode": "none",
                                 "command": ["chown", "-R", service["user"], "/data"],
                                 "volumes": service["volumes"]}
    service["depends_on"] = {"init": {"condition": "service_completed_successfully"}}
    smoke_file = root / "vaultwarden-smoke.json"
    smoke_file.write_text(json.dumps(model))
    command = ["docker", "compose", "-p", f"homelab-vw-check-{os.getpid()}", "-f", str(smoke_file)]
    password = "Audit-not-in-logs-7f3c9a"

    def curl(*arguments):
        cid = run(command + ["ps", "-q", "vaultwarden"], env=environment).strip()
        network = next(iter(json.loads(run(["docker", "inspect", "--format",
                                            "{{json .NetworkSettings.Networks}}", cid]))))
        return run(["docker", "run", "--rm", "--network", network, "labber-unit",
                    "curl", "-sS", *arguments])

    def code(path, *arguments):
        return curl("-o", "/dev/null", "-w", "%{http_code}", *arguments, f"http://vaultwarden:8080{path}").strip()

    try:
        run(command + ["up", "-d", "--wait", "--wait-timeout", "90"], env=environment)
        assert code("/alive") == "200"
        uid = run(command + ["exec", "-T", "vaultwarden", "id", "-u"], env=environment).strip()
        assert uid != "0", "running as root"
        # a sign-up attempt is refused, and a password sent along never reaches the logs
        reply = curl("-X", "POST", "-H", "Content-Type: application/json",
                     "-d", json.dumps({"email": "someone@example.org", "name": password}),
                     "http://vaultwarden:8080/identity/accounts/register/send-verification-email")
        assert "registration not allowed" in reply.lower(), reply[:200]
        # without ADMIN_TOKEN, /admin is a "disabled" page and the admin login is refused
        assert "disabled" in curl("-L", "http://vaultwarden:8080/admin").lower(), "the admin page must be off"
        assert code("/admin", "-X", "POST", "-d", "token=anything") != "200" or \
            "disabled" in curl("-X", "POST", "-d", "token=anything", "http://vaultwarden:8080/admin").lower()
        key = run(command + ["exec", "-T", "vaultwarden", "sha256sum", "/data/rsa_key.pem"], env=environment)
        run(command + ["restart", "vaultwarden"], env=environment)
        run(command + ["up", "-d", "--wait", "--wait-timeout", "60"], env=environment)
        assert run(command + ["exec", "-T", "vaultwarden", "sha256sum", "/data/rsa_key.pem"], env=environment) == key, \
            "the signing key changed across a restart (logins would break)"
        logs = run(command + ["logs", "--no-color", "vaultwarden"], env=environment)
        assert password not in logs, "a password from a request appeared in the logs"
        print("ok   Vaultwarden runs as non-root; sign-ups and the admin page refused; key kept across a restart; no password in logs")
    except (SystemExit, AssertionError):
        print(run(command + ["logs", "--no-color"], env=environment), flush=True)
        raise
    finally:
        run(command + ["down", "--volumes", "--remove-orphans"], env=environment)
