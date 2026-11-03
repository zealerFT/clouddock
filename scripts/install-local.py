#!/usr/bin/env python3
"""Replace the single project App from the built ZIP, only after it has quit."""
from pathlib import Path
import argparse
import json
import plistlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--if-idle', action='store_true', help='Leave a running App intact and keep the new installer ready')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    version = json.loads((root / 'version.json').read_text())['version']
    target = root / 'dist/CloudDock.app'
    archive = root / f'dist/CloudDock-{version}-arm64.zip'

    def active():
        output = subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True)
        return any(line.strip().startswith(str(target) + '/') for line in output.splitlines())

    if active():
        message = 'CloudDock 正在运行，旧 App 保持不变。新版安装包已就绪；请 ⌘Q 退出后运行 python3 scripts/install-local.py 原位更新。'
        if args.if_idle:
            print(message)
            return
        raise SystemExit(message)
    if not archive.is_file():
        raise SystemExit(f'请先运行 bash scripts/package.sh 生成 {version} 安装包。')

    with tempfile.TemporaryDirectory(prefix='.clouddock-install-', suffix='.noindex', dir=target.parent) as temporary:
        stage = Path(temporary)
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(stage)], check=True)
        app = stage / 'CloudDock.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != 'app.clouddock.mac' or info.get('CFBundleShortVersionString') != version:
            raise SystemExit('安装包标识或版本不符，未替换 App。')
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        if active():
            raise SystemExit('CloudDock 已重新打开，未替换 App。请退出后重试。')
        backup = stage / 'previous.noindex/CloudDock.app'
        backup.parent.mkdir()
        if target.exists():
            target.rename(backup)
        try:
            app.rename(target)
        except BaseException:
            if backup.exists():
                backup.rename(target)
            raise

    register = Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister')
    subprocess.run([str(register), '-f', str(target)], check=True)
    print(f'已在原位置更新 CloudDock {info["CFBundleShortVersionString"]}：{target}')


if __name__ == '__main__':
    main()
