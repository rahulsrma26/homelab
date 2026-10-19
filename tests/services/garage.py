"""Run a real single-node Garage: signed S3 access, refused anonymous access, restarts."""

import json
import os


def check_garage(config, root, environment, run):
    model = json.loads(json.dumps(config))
    model.pop("name", None)
    service = model["services"]["garage"]
    published = {port["target"] for port in service.get("ports", [])}
    assert published == {3900}, "only the S3 API may be published (RPC and admin stay inside)"
    assert service.get("user") and not service["user"].startswith("0"), "Garage must not run as root"
    settings = service["environment"]
    key, secret, bucket = (settings[name] for name in
                           ("GARAGE_DEFAULT_ACCESS_KEY", "GARAGE_DEFAULT_SECRET_KEY", "GARAGE_DEFAULT_BUCKET"))
    assert key.startswith("GK") and len(key) == 26 and len(secret) == 64

    service.pop("ports", None)
    service.pop("container_name", None)
    service["restart"] = "no"
    model["networks"] = {"default": {"internal": True}}
    config_file = next(v for v in service["volumes"] if v["target"] == "/etc/garage.toml")
    service["volumes"] = [config_file,
                          {"type": "volume", "source": "meta", "target": "/meta"},
                          {"type": "volume", "source": "data", "target": "/data"}]
    model["volumes"] = {"meta": {}, "data": {}}
    # Named volumes start root-owned; the image has no shell to fix that itself.
    init = {"image": "labber-unit", "user": "0:0", "network_mode": "none",
            "command": ["chown", "-R", service["user"], "/meta", "/data"],
            "volumes": service["volumes"][1:]}
    model["services"]["init"] = init
    service["depends_on"] = {"init": {"condition": "service_completed_successfully"}}
    smoke_file = root / "garage-smoke.json"
    smoke_file.write_text(json.dumps(model))
    command = ["docker", "compose", "-p", f"homelab-garage-check-{os.getpid()}", "-f", str(smoke_file)]
    (root / "garage-object").write_text("homelab garage check\n")
    url = f"http://garage:3900/{bucket}/check/object"

    def curl(*arguments):
        cid = run(command + ["ps", "-q", "garage"], env=environment).strip()
        network = next(iter(json.loads(run(["docker", "inspect", "--format",
                                            "{{json .NetworkSettings.Networks}}", cid]))))
        return run(["docker", "run", "--rm", "--network", network, "-v", f"{root}:/work",
                    "labber-unit", "curl", "-sS", *arguments])

    def signed(*arguments, password=secret):
        return curl("--aws-sigv4", "aws:amz:garage:s3", "--user", f"{key}:{password}", *arguments)

    def status(*arguments):
        return int(curl("-o", "/dev/null", "-w", "%{http_code}", *arguments).strip())

    try:
        run(command + ["up", "-d", "--wait", "--wait-timeout", "90"], env=environment)
        signed("-f", "-T", "/work/garage-object", url)
        assert signed("-f", url) == "homelab garage check\n"
        assert status(url) == 403, "anonymous read was allowed"
        assert status("-T", "/work/garage-object", f"http://garage:3900/{bucket}/anonymous") == 403
        code = int(signed("-o", "/dev/null", "-w", "%{http_code}", url, password="b" * 64).strip())
        assert code == 403, f"a wrong secret was accepted: {code}"
        print("ok   Garage serves signed S3 requests and refuses anonymous or wrongly signed ones")

        # Restarts re-run the single-node bootstrap against existing data.
        run(command + ["down"], env=environment)
        run(command + ["up", "-d", "--wait", "--wait-timeout", "90"], env=environment)
        assert signed("-f", url) == "homelab garage check\n"
        print("ok   Garage keeps its layout, key, bucket and objects across a restart")
    except SystemExit:
        print(run(command + ["logs", "--no-color"], env=environment))
        raise
    finally:
        run(command + ["down", "--volumes", "--remove-orphans"], env=environment)
