#!/usr/bin/env python3
"""Fetch a pinned, checksum-verified ARM64 engine; no global installation."""
import hashlib
from pathlib import Path
import subprocess
import zipfile

VERSION = '1.75.2'
SHA256 = '610ab7d48615135dfc60b763858b11a426a0d3d1160c1bb76fb0ae6011b02edd'
ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'vendor'
VENDOR.mkdir(exist_ok=True)
archive = VENDOR / f'rclone-v{VERSION}-osx-arm64.zip'
url = f'https://downloads.rclone.org/v{VERSION}/{archive.name}'
if not archive.exists():
    temporary = archive.with_suffix('.download')
    subprocess.run(['curl', '-fL', '--retry', '2', '--connect-timeout', '20', '--max-time', '300', url, '-o', str(temporary)], check=True)
    temporary.replace(archive)
actual = hashlib.sha256(archive.read_bytes()).hexdigest()
if actual != SHA256:
    raise SystemExit(f'Checksum mismatch: {archive}. Remove this archive and fetch again.')
with zipfile.ZipFile(archive) as z:
    prefix = f'rclone-v{VERSION}-osx-arm64/'
    for name in ['rclone', 'README.txt']:
        destination = VENDOR / name
        content = z.read(prefix + name)
        if not destination.exists() or destination.read_bytes() != content:
            # Never modify a running Mach-O in place (macOS code-signing cache).
            replacement = destination.with_suffix('.new')
            replacement.write_bytes(content)
            if name == 'rclone':
                replacement.chmod(0o755)
            replacement.replace(destination)
(VENDOR / 'rclone').chmod(0o755)
print(f'rclone {VERSION}: ARM64 archive SHA-256 verified')
