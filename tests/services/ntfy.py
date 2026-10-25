"""Run a real ntfy: nothing without a login, send-only and read-only tokens kept apart, the
admin login works, messages survive a restart, Alertmanager's webhook becomes readable text,
and no token or password reaches the logs."""

import json
import os
import secrets


def check_ntfy(config, root, environment, run):
    model = json.loads(json.dumps(config))
    model.pop("name", None)
    service = model["services"]["ntfy"]
    settings = service["environment"]
    assert not service["image"].endswith(":latest"), "pin the ntfy version"
    assert service.get("user") and not service["user"].startswith("0"), "ntfy must not run as root"
    assert settings["NTFY_AUTH_DEFAULT_ACCESS"] == "deny-all"
    assert settings["NTFY_ENABLE_SIGNUP"] == "false"
    tokens = [entry.split(":") for entry in settings["NTFY_AUTH_TOKENS"].split(",")]
    assert [(t[0], t[1][:3], len(t[1])) for t in tokens] == [("publisher", "tk_", 32), ("reader", "tk_", 32)]
    # the suite fills every generated value alike; labber makes them random: two distinct ones here
    publish, read = "tk_" + secrets.token_hex(16)[:29], "tk_" + secrets.token_hex(16)[:29]
    settings["NTFY_AUTH_TOKENS"] = f"publisher:{publish}:publish,reader:{read}:read"
    password = model["services"]["ntfy-auth"]["environment"]["NTFY_ADMIN_PASSWORD"]

    for svc in model["services"].values():
        svc.pop("ports", None)
        svc.pop("container_name", None)
    service["restart"] = "no"
    model["networks"] = {"default": {"internal": True}}
    # named volumes instead of the template's folders; the data one handed to ntfy's user first
    model["services"]["ntfy-auth"]["volumes"] = [{"type": "volume", "source": "config", "target": "/config"}]
    service["volumes"] = [{"type": "volume", "source": "data", "target": "/var/lib/ntfy"},
                          {"type": "volume", "source": "config", "target": "/etc/ntfy", "read_only": True}]
    model["volumes"] = {"data": {}, "config": {}}
    model["services"]["init"] = {"image": "labber-unit", "user": "0:0", "network_mode": "none",
                                 "command": ["chown", "-R", service["user"], "/var/lib/ntfy"],
                                 "volumes": [{"type": "volume", "source": "data", "target": "/var/lib/ntfy"}]}
    service["depends_on"]["init"] = {"condition": "service_completed_successfully"}
    smoke_file = root / "ntfy-smoke.json"
    smoke_file.write_text(json.dumps(model))
    command = ["docker", "compose", "-p", f"homelab-ntfy-check-{os.getpid()}", "-f", str(smoke_file)]

    def curl(*arguments):
        cid = run(command + ["ps", "-q", "ntfy"], env=environment).strip()
        network = next(iter(json.loads(run(["docker", "inspect", "--format",
                                            "{{json .NetworkSettings.Networks}}", cid]))))
        return run(["docker", "run", "--rm", "--network", network, "labber-unit", "curl", "-sS", *arguments])

    def code(*arguments):
        return curl("-o", "/dev/null", "-w", "%{http_code}", *arguments).strip()

    url = "http://ntfy:8080"
    bearer = lambda token: ["-H", f"Authorization: Bearer {token}"]
    try:
        run(command + ["up", "-d", "--wait", "--wait-timeout", "90"], env=environment)
        assert run(command + ["exec", "-T", "ntfy", "id", "-u"], env=environment).strip() != "0", "running as root"
        assert code("-d", "x", f"{url}/checks") == "403", "anonymous publishing must be refused"
        assert code(f"{url}/checks/json?poll=1") == "403", "anonymous reading must be refused"
        assert code(*bearer(publish), "-d", "first message", f"{url}/checks") == "200"
        assert code(*bearer(publish), f"{url}/checks/json?poll=1") == "403", "the publish token must not read"
        assert code(*bearer(read), "-d", "x", f"{url}/checks") == "403", "the read token must not publish"
        alert = {"version": "4", "status": "firing", "receiver": "test", "groupKey": "k", "truncatedAlerts": 0,
                 "commonLabels": {"alertname": "TestAlert", "severity": "warning"},
                 "commonAnnotations": {"summary": "a test alert from the check"}, "externalURL": "http://am",
                 "alerts": [{"status": "firing", "labels": {"alertname": "TestAlert", "instance": "x"},
                             "annotations": {"summary": "a test alert from the check"}, "startsAt": "2026-01-01T00:00:00Z"}]}
        assert code(*bearer(publish), "-H", "Content-Type: application/json", "-d", json.dumps(alert),
                    f"{url}/checks?template=alertmanager") == "200", "Alertmanager's webhook was refused"
        run(command + ["restart", "ntfy"], env=environment)
        run(command + ["up", "-d", "--wait", "--wait-timeout", "60"], env=environment)
        messages = [json.loads(line) for line in curl(*bearer(read), f"{url}/checks/json?poll=1").splitlines() if line.strip()]
        texts = [m.get("message", "") + " " + m.get("title", "") for m in messages if m.get("event") == "message"]
        assert any("first message" in t for t in texts), f"messages lost across a restart: {texts}"
        assert any("TestAlert" in t and "test alert from the check" in t and '"version"' not in t for t in texts), \
            f"the Alertmanager message isn't readable text: {texts}"
        assert code("-u", f"admin:{password}", f"{url}/checks/json?poll=1") == "200", "the admin login failed"
        assert code("-u", "admin:wrong", f"{url}/checks/json?poll=1") in ("401", "403")
        logs = run(command + ["logs", "--no-color"], env=environment)
        for secret in (publish, read, password):
            assert secret not in logs, "a token or password appeared in the logs"
        print("ok   ntfy: nothing without a login; send-only and read-only tokens apart; admin login; "
              "messages kept across a restart; Alertmanager webhook readable; no secret in logs", flush=True)
    except (SystemExit, AssertionError):
        print(run(command + ["logs", "--no-color"], env=environment), flush=True)
        raise
    finally:
        run(command + ["down", "--volumes", "--remove-orphans"], env=environment)
