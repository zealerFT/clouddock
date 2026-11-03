#!/usr/bin/env python3
"""Run Swift tests against a disposable, authenticated localhost S3 server."""
from pathlib import Path
import os
import socket
import subprocess
import tempfile
import time
import urllib.request
import urllib.error

root = Path(__file__).resolve().parents[1]
binary = root / 'vendor/rclone'
python = root / '.qa-venv/bin/python'
moto = root / '.qa-venv/bin/moto_server'
if not moto.exists():
    raise SystemExit('Install the QA fixture first: uv venv .qa-venv && uv pip install --python .qa-venv/bin/python -r requirements-qa.txt')
with tempfile.TemporaryDirectory(prefix='clouddock-s3-fixture-') as temporary:
    folder = Path(temporary)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    endpoint = f'http://127.0.0.1:{port}'
    with (folder / 'server.log').open('w') as log:
        server = subprocess.Popen([str(moto), '-H', '127.0.0.1', '-p', str(port)], stdout=log, stderr=log)
        try:
            ready = False
            for _ in range(100):
                if server.poll() is not None:
                    raise RuntimeError((folder / 'server.log').read_text())
                try:
                    urllib.request.urlopen(endpoint, timeout=0.2).close()
                    ready = True
                except urllib.error.HTTPError:
                    ready = True
                except (urllib.error.URLError, TimeoutError):
                    time.sleep(0.1)
                if ready:
                    break
            if not ready:
                raise RuntimeError('Local fixture did not become ready')
            subprocess.run([str(python), '-c',
                'import boto3,sys; boto3.client("s3", endpoint_url=sys.argv[1], aws_access_key_id="clouddock-fixture", aws_secret_access_key="fixture-only-not-a-real-secret", region_name="us-east-1").create_bucket(Bucket="fixture")',
                endpoint], check=True)
            subprocess.run([str(python), str(root / 'scripts/seed-paging-fixture.py'), endpoint], check=True)
            env = os.environ.copy()
            env.update(CLOUDDOCK_TEST_ENDPOINT=endpoint, CLOUDDOCK_RCLONE=str(binary))
            result = subprocess.run(['swift', 'run', 'CloudDockChecks'], cwd=root, env=env)
            if result.returncode:
                print((folder / 'server.log').read_text()[-5000:])
            raise SystemExit(result.returncode)
        finally:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
