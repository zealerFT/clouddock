#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
INSTALL_LOCAL=true
if [[ "${1:-}" == --no-install && $# == 1 ]]; then
    INSTALL_LOCAL=false
elif [[ $# != 0 ]]; then
    echo 'Usage: bash scripts/package.sh [--no-install]' >&2
    exit 1
fi
read -r VERSION BUILD_NUMBER < <(python3 -c 'import json; v=json.load(open("version.json")); print(v["version"], v["build"])')
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]
python3 scripts/check-public-files.py
python3 scripts/fetch-rclone.py
swift build -c release --product CloudDock --arch arm64 \
    -Xswiftc -gnone \
    -Xswiftc -file-prefix-map -Xswiftc "$TASK_ROOT=/clouddock"
PACKAGE_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/clouddock-package.XXXXXX")"
trap 'rm -rf -- "$PACKAGE_TEMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
APP="$PACKAGE_TEMP/build.noindex/CloudDock.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist
cp .build/arm64-apple-macosx/release/CloudDock "$APP/Contents/MacOS/CloudDock"
# SwiftPM release builds contain object-file paths unless debug symbols are removed.
strip -S "$APP/Contents/MacOS/CloudDock"
cp vendor/rclone "$APP/Contents/Resources/rclone"
cp vendor/README.txt "$APP/Contents/Resources/RCLONE-README.txt"
cp README.md "$APP/Contents/Resources/CloudDock-README.md"
cp README.zh-CN.md "$APP/Contents/Resources/CloudDock-README.zh-CN.md"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
swift scripts/make-icon.swift "$PACKAGE_TEMP/CloudDock.iconset"
iconutil -c icns "$PACKAGE_TEMP/CloudDock.iconset" -o "$APP/Contents/Resources/CloudDock.icns"
python3 - "$APP" "$VERSION" "$BUILD_NUMBER" <<'PY'
import plistlib, sys
from pathlib import Path
app = Path(sys.argv[1])
info = {
 'CFBundleName': 'CloudDock', 'CFBundleDisplayName': 'CloudDock',
 'CFBundleIdentifier': 'app.clouddock.mac', 'CFBundleExecutable': 'CloudDock',
 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': sys.argv[2], 'CFBundleVersion': sys.argv[3],
 'CFBundleIconFile': 'CloudDock', 'LSMinimumSystemVersion': '14.0',
 'LSApplicationCategoryType': 'public.app-category.utilities',
 'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication',
 # Users may intentionally configure plain-http MinIO/S3-compatible endpoints.
 # HTTPS remains the preferred endpoint and is still used by all hosted services.
 'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True},
 'NSHumanReadableCopyright': 'CloudDock. Includes rclone; see Third Party Notices.',
}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$APP/Contents/Resources/rclone"
codesign --force --sign - --identifier app.clouddock.mac "$APP"
codesign --verify --deep --strict "$APP"
STAGE="$PACKAGE_TEMP/staging.noindex"
mkdir -p "$STAGE"
ditto --noextattr --norsrc "$APP" "$STAGE/CloudDock.app"
ln -s /Applications "$STAGE/Applications"
cp INSTALL.txt "$STAGE/安装说明.txt"
hdiutil create -volname CloudDock -srcfolder "$STAGE" -ov -format UDZO "dist/CloudDock-$VERSION-arm64.dmg"
ditto -c -k --noextattr --norsrc --keepParent "$APP" "dist/CloudDock-$VERSION-arm64.zip"
python3 - "$VERSION" <<'PY'
import subprocess, sys, zipfile
from pathlib import Path
root = Path.cwd()
with zipfile.ZipFile(root / f'dist/CloudDock-{sys.argv[1]}-source.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    # In a checkout, only reviewed Git paths enter the archive. No local notes/data.
    files = subprocess.check_output([sys.executable, 'scripts/check-public-files.py', '--list'], text=True).splitlines()
    for file in files:
        archive.write(root / file, 'clouddock/' + file)
PY
(
    cd dist
    shasum -a 256 "CloudDock-$VERSION-arm64.dmg" "CloudDock-$VERSION-arm64.zip" "CloudDock-$VERSION-source.zip" > SHA256SUMS
)
if [[ "$INSTALL_LOCAL" == true ]]; then
    python3 scripts/install-local.py --if-idle
fi
printf 'Built CloudDock %s for macOS Apple Silicon.\n' "$VERSION"
