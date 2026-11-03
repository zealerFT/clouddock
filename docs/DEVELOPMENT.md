# Developing CloudDock

The source of truth is the Git checkout of [zealerFT/clouddock](https://github.com/zealerFT/clouddock). Continue work in that checkout so edits, tests, and releases refer to the same source history.

## Local workflow

```bash
git status --short --branch
git remote -v
git pull --ff-only
```

Run the pull only with a clean working tree; preserve unfinished changes first. Use a focused branch for a contribution, make changes in the source tree, run the relevant checks, then review and commit the diff. Use your GitHub no-reply email if you do not want to publish a personal email address.

```bash
python3 scripts/fetch-rclone.py
swift run CloudDockChecks
python3 scripts/check-public-files.py
git diff --check
bash scripts/package.sh
```

Packaging builds an Apple Silicon app and installs it at `dist/CloudDock.app` when that copy is idle. If it is running, quit it and run `python3 scripts/install-local.py` to update the same copy. `bash scripts/package.sh --no-install` only produces release archives. Installing a new bundle must preserve app state and credentials in Application Support.

Stage intentional files before preparing a source archive: in a Git checkout, the archive contains only tracked paths. The public-file check examines the contents of those paths in the working tree, so review staged and unstaged changes before committing. A source archive can also be built without Git; its fallback file list is defined in `scripts/check-public-files.py`.

## Architecture

```text
SwiftUI / AppKit → AppStore → CloudDockCore → storage service
                              ├─ native paginated listing and signing
                              └─ bundled rclone transfers
```

- `Sources/CloudDock`: windows, connection editor, file browser, previews, sharing, transfers, and operation history.
- `Sources/CloudDockCore`: models, credentials, protocols, pagination, transfer processes, signing, QR generation, and audit persistence.
- `Tests/CloudDockCoreTests`: standalone Swift checks and integration fixtures; run with `swift run CloudDockChecks`.
- `scripts`: pinned dependency fetching, local test fixtures, packaging, and local installation.
- `version.json`: shared app version and monotonically increasing build number.

Keep the macOS 14 minimum and Swift 5 language compatibility. Runtime dependencies are macOS system frameworks and bundled rclone. Python and Moto are development tools and are not required by the installed app. File moves use copy then delete; paginated sorting applies to the current page.

## Testing storage changes

```bash
python3 -m venv .qa-venv
.qa-venv/bin/python -m pip install -r requirements-qa.txt
python3 scripts/integration-test.py
```

This starts an isolated Moto server on a random localhost port and removes it after the checks. Additional MinIO, LocalStack, and fake-gcs-server runners are documented in the main README. Use synthetic files and disposable buckets. Emulator tests do not validate hosted-cloud IAM, Finder drag-and-drop, or system permission dialogs.

## Public data boundary

Commit source, tests with fake credentials, documentation, and reviewed assets. Keep `dist/`, `.build/`, `vendor/`, virtual environments, `docs/ai-dev/`, app state, audit logs, and credentials local. The public-file check catches known token formats, private-key payloads, private file paths, and common user-data files; it supplements manual review rather than proving that arbitrary text is free of sensitive data.

For a release, use a clean commit and the tag-driven workflow in [PUBLISHING.md](PUBLISHING.md). The workflow checks the tag against `version.json`, tests the source, builds the installers, and publishes downloadable assets.
