"""Forgejo's s3 storage mode against a real Garage: uploads land in the bucket, and an
outage blocks only a restart, which recovers by itself once the bucket is back."""

import json
import os
import secrets
import time


def check_forgejo_s3(variants, garage_config, root, environment, run):
    local = variants["local"]["services"]["forgejo"]["environment"]
    s3 = variants["s3"]["services"]["forgejo"]["environment"]
    assert not any(key.endswith("__STORAGE_TYPE") for key in local), "local mode must not use S3"
    for section in ("packages", "actions_0X2E_artifacts"):
        assert s3[f"FORGEJO__{section}__STORAGE_TYPE"] == "minio"
        assert s3[f"FORGEJO__{section}__MINIO_BUCKET_LOOKUP"] == "path"
    # Logs stay local; [storage.packages] next to [packages] stops Forgejo at start.
    assert not any("actions_log" in key or "storage_0X2E_packages" in key for key in s3)
    assert local["FORGEJO__packages__ENABLED"] == "false"
    assert local["FORGEJO__actions__ARTIFACT_RETENTION_DAYS"] == "7"
    assert local["FORGEJO__actions__LOG_RETENTION_DAYS"] == "90"

    model = json.loads(json.dumps(variants["s3"]))
    model.pop("name", None)
    garage_model = json.loads(json.dumps(garage_config))
    garage = garage_model["services"]["garage"]
    key = garage["environment"]["GARAGE_DEFAULT_ACCESS_KEY"]
    secret = garage["environment"]["GARAGE_DEFAULT_SECRET_KEY"]
    bucket = garage["environment"]["GARAGE_DEFAULT_BUCKET"]
    for service in (garage, model["services"]["forgejo"]):
        service.pop("ports", None)
        service.pop("container_name", None)
    garage["restart"] = "no"
    config_file = next(v for v in garage["volumes"] if v["target"] == "/etc/garage.toml")
    garage["volumes"] = [config_file, {"type": "volume", "source": "meta", "target": "/meta"},
                         {"type": "volume", "source": "data", "target": "/data"}]
    model["services"]["init"] = {"image": "labber-unit", "user": "0:0", "network_mode": "none",
                                 "command": ["chown", "-R", garage["user"], "/meta", "/data"],
                                 "volumes": garage["volumes"][1:]}
    garage["depends_on"] = {"init": {"condition": "service_completed_successfully"}}
    model["services"]["garage"] = garage

    forgejo = model["services"]["forgejo"]
    forgejo["restart"] = "unless-stopped"     # the real policy: retry until the bucket is back
    settings = forgejo["environment"]
    settings.update({"FORGEJO__server__ROOT_URL": "http://forgejo:3000/", "FORGEJO__server__DOMAIN": "forgejo",
                     "FORGEJO__packages__ENABLED": "true"})
    for section in ("packages", "actions_0X2E_artifacts"):
        settings.update({f"FORGEJO__{section}__MINIO_ENDPOINT": "garage:3900",
                         f"FORGEJO__{section}__MINIO_BUCKET": bucket,
                         f"FORGEJO__{section}__MINIO_ACCESS_KEY_ID": key,
                         f"FORGEJO__{section}__MINIO_SECRET_ACCESS_KEY": secret})
    forgejo["volumes"] = [{"type": "volume", "source": "forgejo", "target": "/data"}]
    model["volumes"] = {"meta": {}, "data": {}, "forgejo": {}}
    model["networks"] = {"default": {"internal": True}}
    project = f"homelab-forgejo-s3-check-{os.getpid()}"
    smoke_file = root / "forgejo-s3-smoke.json"
    smoke_file.write_text(json.dumps(model))
    command = ["docker", "compose", "-p", project, "-f", str(smoke_file)]
    password = secrets.token_hex(24)
    (root / "package.txt").write_text("homelab package check\n")
    package = "http://forgejo:3000/api/packages/audit/generic/check/1.0/package.txt"

    def curl(*arguments):
        return run(["docker", "run", "--rm", "--network", f"{project}_default", "-v", f"{root}:/work",
                    "labber-unit", "curl", "-sS", "-m", "10", *arguments])

    def health():
        cid = run(command + ["ps", "-aq", "forgejo"], env=environment).strip()
        state = json.loads(run(["docker", "inspect", "--format", "{{json .State}}", cid]))
        return state.get("Health", {}).get("Status") if state["Running"] else "stopped"

    def wait_for(wanted, seconds):
        deadline = time.time() + seconds
        while time.time() < deadline:
            if health() == wanted:
                return True
            time.sleep(3)
        return False

    try:
        run(command + ["up", "-d", "--wait", "--wait-timeout", "120"], env=environment)
        run(command + ["exec", "-T", "--user", "git", "forgejo", "forgejo", "--config", "/data/gitea/conf/app.ini",
                       "admin", "user", "create", "--username", "audit", "--email", "audit@example.org",
                       "--password", password, "--admin", "--must-change-password=false"], env=environment)
        code = curl("-o", "/dev/null", "-w", "%{http_code}", "--user", f"audit:{password}",
                    "--upload-file", "/work/package.txt", package).strip()
        assert code == "201", f"package upload failed: {code}"
        assert curl("-f", "--user", f"audit:{password}", package) == "homelab package check\n"
        listing = curl("-f", "--aws-sigv4", "aws:amz:garage:s3", "--user", f"{key}:{secret}",
                       f"http://garage:3900/{bucket}?list-type=2")
        assert "<Key>packages/" in listing, "the package is not in the bucket"
        print("ok   Forgejo's s3 mode stores packages in Garage")

        run(command + ["stop", "garage"], env=environment)
        api = curl("-o", "/dev/null", "-w", "%{http_code}", "--user", f"audit:{password}",
                   "http://forgejo:3000/api/v1/user").strip()
        assert api == "200", f"a running Forgejo stopped serving without its bucket: {api}"
        run(command + ["restart", "forgejo"], env=environment)
        time.sleep(20)
        assert health() != "healthy", "Forgejo started without its S3 storage"
        run(command + ["start", "garage"], env=environment)
        assert wait_for("healthy", 180), "Forgejo did not recover after the bucket came back"
        assert curl("-f", "--user", f"audit:{password}", package) == "homelab package check\n"
        print("ok   without its bucket a running Forgejo serves Git, a restart waits, and it recovers by itself")
    except (SystemExit, AssertionError):
        print(run(command + ["logs", "--no-color", "--tail", "40"], env=environment))
        raise
    finally:
        run(command + ["down", "--volumes", "--remove-orphans"], env=environment)
