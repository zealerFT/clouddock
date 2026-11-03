# Working on CloudDock

- Use this Git checkout as the development source. Confirm the repository root, branch, and working tree before making changes. The upstream is `zealerFT/clouddock`; do not develop in an extracted release or create a parallel unmanaged copy.
- Keep changes in `Sources/`, `Tests/`, `scripts/`, and public documentation as appropriate. Preserve existing user changes. Build products in `dist/` and `.build/` are generated, not source.
- Keep the native SwiftUI/AppKit + Swift Package Manager architecture and bundled rclone. Read [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) before changing storage behavior or packaging.
- Never commit credentials, service-account files, app state/history, signed download URLs, personal filesystem paths, or private development notes. Test with explicit fake credentials and disposable local buckets. Never read or modify a developer's saved cloud connections for testing.
- Run `python3 scripts/check-public-files.py` and the checks relevant to the change. Storage changes require local integration coverage. Keep the English and Chinese READMEs consistent; distinguish emulator checks from hosted-cloud validation.
- Use `version.json` for the app version and build number. Follow [docs/PUBLISHING.md](docs/PUBLISHING.md) for releases. Publish installers as GitHub Release assets, not Git commits. Never move a published tag or replace its assets with different builds.
- Local builds can update the existing `dist/CloudDock.app` via `scripts/install-local.py`. Keep one installed copy and preserve user data. Do not claim an update was installed if the app was running and installation was skipped.
