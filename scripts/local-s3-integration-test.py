#!/usr/bin/env python3
"""Check native listing -> rclone operations on disposable MinIO and LocalStack containers."""
from pathlib import Path
import argparse
import os
import socket
import subprocess
import time
import urllib.request
import uuid

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--provider', choices=['minio', 'aws'], help='Run only one fixture (aws means LocalStack)')
args = parser.parse_args()
python = root / '.qa-venv/bin/python'
subprocess.run(['swift', 'build', '--product', 'CloudDockChecks'], cwd=root, check=True)
bin_path = subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip()

# Existing user containers, their ports, volumes and credentials are never used.
fixtures = [
    ('minio', 'docker.io/bitnamilegacy/minio:2025.5.24-debian-12-r5', 9000,
     ['--entrypoint', '/opt/bitnami/minio/bin/minio', '-e', 'MINIO_ROOT_USER=clouddock-fixture',
      '-e', 'MINIO_ROOT_PASSWORD=fixture-only-not-a-real-secret'],
     ['server', '/tmp/clouddock-data', '--address', ':9000'], '/minio/health/ready'),
    ('aws', 'docker.io/localstack/localstack:3.8.1-arm64', 4566,
     ['-e', 'SERVICES=s3', '-e', 'PERSISTENCE=0'], [], '/_localstack/health'),
]
for provider, image, port, options, command, health in fixtures:
    if args.provider and args.provider != provider:
        continue
    name = 'clouddock-compat-' + provider + '-' + uuid.uuid4().hex[:10]
    try:
        # Podman's VM allocator cannot see ports already occupied on the macOS host.
        with socket.socket() as available:
            available.bind(('127.0.0.1', 0))
            host_port = available.getsockname()[1]
        subprocess.run(['podman', 'run', '--pull=never', '--rm', '--detach', '--name', name,
                        '-p', f'127.0.0.1:{host_port}:{port}', *options, image, *command], check=True, stdout=subprocess.DEVNULL)
        mapping = subprocess.check_output(['podman', 'port', name, f'{port}/tcp'], text=True).strip()
        endpoint = 'http://localhost:' + mapping.rsplit(':', 1)[1]
        for _ in range(100):
            try:
                urllib.request.urlopen(endpoint + health, timeout=.5).close()
                break
            except (OSError, urllib.error.URLError):
                time.sleep(.2)
        else:
            raise RuntimeError(f'{provider} fixture did not become ready')
        subprocess.run([str(python), '-c',
            'import boto3,sys; from botocore.config import Config; '
            'boto3.client("s3", endpoint_url=sys.argv[1], aws_access_key_id="clouddock-fixture", '
            'aws_secret_access_key="fixture-only-not-a-real-secret", region_name="us-east-1", '
            'config=Config(s3={"addressing_style":"path"})).create_bucket(Bucket="fixture")', endpoint], check=True)
        env = os.environ.copy()
        env.update(CLOUDDOCK_COMPAT_ENDPOINT=endpoint, CLOUDDOCK_COMPAT_PROVIDER=provider,
                   CLOUDDOCK_RCLONE=str(root / 'vendor/rclone'))
        print(f'Checking disposable {provider} fixture ({image})', flush=True)
        try:
            subprocess.run([str(Path(bin_path) / 'CloudDockChecks'), '--filter', 'Local S3 compatibility'],
                           cwd=root, env=env, check=True, timeout=180)
        except subprocess.CalledProcessError:
            logs = subprocess.check_output(['podman', 'logs', '--tail', '60', name], text=True, stderr=subprocess.STDOUT)
            print(logs)
            # Only disposable fixture names are printed; never dump credentials or request headers.
            subprocess.run([str(python), '-c', '''
import boto3,sys,urllib.request,urllib.parse,xml.etree.ElementTree as ET
from botocore.config import Config
from botocore.auth import S3SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.credentials import Credentials
c=boto3.client('s3',endpoint_url=sys.argv[1],aws_access_key_id='clouddock-fixture',aws_secret_access_key='fixture-only-not-a-real-secret',region_name='us-east-1',config=Config(s3={'addressing_style':'path'}))
page=c.list_objects_v2(Bucket='fixture',MaxKeys=20)
keys=[x['Key'] for x in page.get('Contents',[])]
print('SDK fixture keys:',keys)
prefix=keys[0].split('/')[0]+'/' if keys else ''
token=None
for index in range(5):
 query={'delimiter':'/','encoding-type':'url','list-type':'2','max-keys':'2','prefix':prefix}
 if token: query['continuation-token']=token
 url=sys.argv[1]+'/fixture/?'+urllib.parse.urlencode(query,quote_via=urllib.parse.quote)
 req=AWSRequest(method='GET',url=url); S3SigV4Auth(Credentials('clouddock-fixture','fixture-only-not-a-real-secret'),'s3','us-east-1').add_auth(req)
 with urllib.request.urlopen(urllib.request.Request(url,headers=dict(req.headers)),timeout=8) as r:
  xml=r.read().decode(); print('Fixture listing XML page',index,':',xml[:8000])
 token=ET.fromstring(xml).findtext('{*}NextContinuationToken')
 if not token: break
''', endpoint], check=False)
            raise
    finally:
        subprocess.run(['podman', 'stop', '--time', '2', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        remaining = subprocess.check_output(['podman', 'ps', '-a', '--filter', 'name=' + name, '--format', '{{.Names}}'], text=True).strip()
        if remaining:
            raise RuntimeError(f'Test container cleanup incomplete: {name}')
        print(f'Removed disposable {provider} fixture', flush=True)
