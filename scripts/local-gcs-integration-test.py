#!/usr/bin/env python3
"""Check native GCS listing and rclone transfers on a disposable fake-gcs-server."""
from pathlib import Path
import argparse
import json
import os
import socket
import subprocess
import time
import urllib.error
import urllib.request
import urllib.parse
import uuid

ROOT = Path(__file__).resolve().parents[1]
IMAGE = "docker.io/fsouza/fake-gcs-server:latest"


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for(url, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=.5) as response:
                response.read()
            return
        except (OSError, urllib.error.URLError):
            time.sleep(.2)
    raise RuntimeError(f"GCS fixture did not become ready: {url}")


def post_json(url, value):
    body = json.dumps(value).encode()
    request = urllib.request.Request(url, data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        if response.status < 200 or response.status >= 300:
            raise RuntimeError(f"GCS fixture returned HTTP {response.status}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", help="Reuse a running localhost emulator; create and clean only a unique test bucket")
    args = parser.parse_args()
    container = None
    bucket = "clouddock-check-" + uuid.uuid4().hex
    created_bucket = False
    endpoint = None
    try:
        if args.endpoint:
            parts = urllib.parse.urlsplit(args.endpoint)
            if parts.hostname not in {"localhost", "127.0.0.1", "::1"} or parts.scheme not in {"http", "https"}:
                raise ValueError("--endpoint must be a localhost test service")
            endpoint = urllib.parse.urlunsplit((parts.scheme, parts.netloc, "/storage/v1/", "", ""))
        else:
            container = "clouddock-gcs-" + uuid.uuid4().hex[:10]
            fake_port = free_port()
            subprocess.run([
                "podman", "run", "--pull=missing", "--rm", "--detach", "--name", container,
                "-p", f"127.0.0.1:{fake_port}:4443", IMAGE,
                "-scheme", "http", "-port", "4443", "-public-host", f"localhost:{fake_port}",
            ], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
            endpoint = f"http://localhost:{fake_port}/storage/v1/"
        wait_for(endpoint + "b")
        post_json(endpoint + "b?project=0", {"name": bucket})
        created_bucket = True

        subprocess.run(["swift", "build", "--product", "CloudDockChecks"], cwd=ROOT, check=True)
        bin_path = Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip())
        environment = os.environ.copy()
        environment.update(CLOUDDOCK_GCS_ENDPOINT=endpoint, CLOUDDOCK_GCS_BUCKET=bucket, CLOUDDOCK_RCLONE=str(ROOT / "vendor/rclone"))
        print(f"Checking GCS fixture at {endpoint}, isolated bucket {bucket}", flush=True)
        subprocess.run([str(bin_path / "CloudDockChecks"), "--filter", "Local GCS compatibility"],
                       cwd=ROOT, env=environment, check=True, timeout=180)
    except subprocess.CalledProcessError:
        if container:
            print("GCS fixture container logs:", flush=True)
            subprocess.run(["podman", "logs", "--tail", "80", container], check=False)
        raise
    finally:
        if container:
            subprocess.run(["podman", "rm", "-f", container], cwd=ROOT,
                           check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            remaining = subprocess.check_output(["podman", "ps", "-a", "--filter", "name=" + container,
                                                 "--format", "{{.Names}}"], cwd=ROOT, text=True).strip()
            if remaining:
                raise RuntimeError(f"Test container cleanup incomplete: {container}")
            print("Removed disposable GCS fixture", flush=True)
        elif created_bucket:
            # This bucket was created by this invocation. Never touch user buckets.
            root = endpoint + "b/" + bucket
            while True:
                with urllib.request.urlopen(root + "/o?maxResults=1000", timeout=10) as response:
                    objects = json.load(response).get("items", [])
                if not objects:
                    break
                for obj in objects:
                    url = root + "/o/" + urllib.parse.quote(obj["name"], safe="")
                    with urllib.request.urlopen(urllib.request.Request(url, method="DELETE"), timeout=10):
                        pass
            with urllib.request.urlopen(urllib.request.Request(root, method="DELETE"), timeout=10):
                pass
            print(f"Removed isolated test bucket {bucket}; existing service unchanged", flush=True)


if __name__ == "__main__":
    main()
