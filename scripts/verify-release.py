#!/usr/bin/env python3
"""Verify the installers and source archive built from the current checkout."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def bundle_contents(app):
    return {
        path.relative_to(app).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in app.rglob('*') if path.is_file()
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=ROOT / 'dist')
    args = parser.parse_args()
    directory = args.directory.resolve()
    metadata = json.loads((ROOT / 'version.json').read_text())
    version = metadata['version']
    assets = [f'CloudDock-{version}-arm64.dmg', f'CloudDock-{version}-arm64.zip', f'CloudDock-{version}-source.zip']
    checksums = {}
    for line in (directory / 'SHA256SUMS').read_text().splitlines():
        digest, name = line.split('  ', 1)
        require(name in assets and name not in checksums, 'Unexpected checksum filename')
        checksums[name] = digest
    require(set(checksums) == set(assets), 'Incomplete checksum manifest')
    for name in assets:
        require(hashlib.sha256((directory / name).read_bytes()).hexdigest() == checksums[name], f'Checksum mismatch: {name}')

    paths = subprocess.check_output(['python3', 'scripts/check-public-files.py', '--list'], cwd=ROOT, text=True).splitlines()
    with zipfile.ZipFile(directory / assets[2]) as archive:
        require(set(archive.namelist()) == {'clouddock/' + p for p in paths}, 'Source archive file set differs from reviewed files')
        for path in paths:
            require(archive.read('clouddock/' + path) == (ROOT / path).read_bytes(), f'Source archive differs: {path}')

    with tempfile.TemporaryDirectory(prefix='clouddock-verify-', suffix='.noindex') as temporary:
        subprocess.run(['ditto', '-x', '-k', str(directory / assets[1]), temporary], check=True)
        app = Path(temporary) / 'CloudDock.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        require(info.get('CFBundleIdentifier') == 'app.clouddock.mac', 'Unexpected app identity')
        require(info.get('CFBundleShortVersionString') == version, 'App version differs from source')
        require(info.get('CFBundleVersion') == str(metadata['build']), 'App build differs from source')
        executable = app / 'Contents/MacOS/CloudDock'
        require(subprocess.check_output(['lipo', '-archs', str(executable)], text=True).strip() == 'arm64', 'App is not ARM64')
        require(not re.search(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/', executable.read_bytes()), 'App contains an absolute user path')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        for original, bundled in [('README.md', 'CloudDock-README.md'), ('README.zh-CN.md', 'CloudDock-README.zh-CN.md'), ('LICENSE', 'LICENSE')]:
            require((app / 'Contents/Resources' / bundled).read_bytes() == (ROOT / original).read_bytes(), f'Bundled document differs: {original}')
        expected_contents = bundle_contents(app)
        image = directory / assets[0]
        subprocess.run(['hdiutil', 'verify', str(image)], check=True)
        mount = Path(temporary) / 'image.noindex'
        mount.mkdir()
        subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(image)], check=True)
        try:
            image_app = mount / 'CloudDock.app'
            require(bundle_contents(image_app) == expected_contents, 'DMG app contents differ from the verified ZIP')
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(image_app)], check=True)
        finally:
            subprocess.run(['hdiutil', 'detach', str(mount)], check=True)
    print(f'CloudDock {version}: checksums, source contents, app version, ARM64, signature, path privacy, and complete DMG app contents verified.')


if __name__ == '__main__':
    main()
