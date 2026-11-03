# Publishing CloudDock

Repository: [zealerFT/clouddock](https://github.com/zealerFT/clouddock). Develop in the Git checkout; see [DEVELOPMENT.md](DEVELOPMENT.md). Binary downloads are published through [GitHub Releases](https://github.com/zealerFT/clouddock/releases).

## Repository metadata

| Field | Value |
| --- | --- |
| Repository | `zealerFT/clouddock` |
| Default branch | `main` |
| License | MIT |
| Default documentation | `README.md` — English |
| Chinese documentation | `README.zh-CN.md` |

Description:

```text
A native macOS object storage client for S3, MinIO, Alibaba Cloud OSS, and Google Cloud Storage, with drag-and-drop transfers, previews, and share links.
```

Topics:

```text
macos apple-silicon swift swiftui s3 minio aliyun-oss google-cloud-storage object-storage rclone file-manager
```

## Prepare a version

1. Work from an up-to-date checkout. Update `version.json` with the semantic version and increment the build number; both packaging and local installation read this file.
2. Update `CHANGELOG.md`, both READMEs when behavior changes, and `docs/releases/vX.Y.Z.md`. State the actual test coverage and any installation limitations.
3. Run the public-file and relevant storage checks, then review the files being committed:

   ```bash
   python3 scripts/fetch-rclone.py
   swift run CloudDockChecks
   python3 scripts/integration-test.py
   git add <reviewed-files>
   python3 scripts/check-public-files.py
   git diff --cached --check
   git diff --cached --stat
   ```

   The Moto suite requires the QA environment described in the README. Run provider-specific local checks when those integrations change. Use a public or GitHub no-reply commit identity.

4. For local packaging verification, run:

   ```bash
   bash scripts/package.sh --no-install
   python3 scripts/verify-release.py
   ```

   If an older DMG at the same path is mounted, eject it in Finder before rebuilding. Verify the new archives, not an already installed app. Normal `bash scripts/package.sh` also updates the existing `dist/CloudDock.app` when it is idle.

5. Commit the reviewed changes. The source ZIP in a checkout includes Git-tracked paths only; keep the working tree clean for an actual release.

## Publish with a tag

For the initial release, the version is `0.5.8`, build `13`:

```bash
git push origin main
git tag -a v0.5.8 -m "CloudDock 0.5.8"
git push origin v0.5.8
```

Replace the example version for subsequent releases. The [release workflow](../.github/workflows/release.yml) builds the tag on a GitHub-hosted Apple Silicon macOS runner. It checks the version, runs the core and Moto suites, builds the packages, and verifies signatures, architecture, source contents, path privacy, and checksums. It creates a draft, uploads all assets, then publishes the release as latest:

- `CloudDock-<version>-arm64.dmg` — drag-to-Applications installer.
- `CloudDock-<version>-arm64.zip` — packaged app.
- `CloudDock-<version>-source.zip` — reviewed source with documentation.
- `SHA256SUMS` — checksums using bare filenames.

The workflow uses GitHub's temporary repository token. No cloud credentials, personal access token, or Apple signing secrets are needed. Current builds are ad-hoc signed and not Apple-notarized; the README and release notes explain first-launch behavior.

Check the workflow result and the published assets before announcing a release. A failed build does not publish the draft. An existing unpublished tag can be retried through **Actions → Publish macOS app → Run workflow**, providing that exact tag. The workflow refuses to overwrite an already published release. For source fixes after publication, use a new version and tag; never move the old tag or silently replace its assets.

Changes to app source, packaging scripts, the version file, or the release workflow on `main` also run build and archive verification without publishing a release. Packaging failures include the last log lines in the check annotations.

For a transient failure of an unpublished tagged release, use **Actions → Retry failed release → Run workflow** with the failed run ID. A maintainer working through Git can instead update `.github/release-retry.json` and push it to `main`. This workflow reports the failed step's log excerpt and reruns the original job using the repository's temporary Actions token. It checks that the tag still points to the original commit and refuses to retry a published release; no personal API token or tag replacement is needed. Diagnose failures before requesting further retries.

Installers use HFS+ with capacity calculated from the staged files' logical sizes, plus 64 MiB of spare space, with a 256 MiB minimum. Verification mounts the DMG read-only, compares its app files with the ZIP, verifies its signature, and detaches the image before completing.

## Public file set

Publish source, fake test fixtures, documentation, and reviewed images. `.gitignore` excludes build products, downloaded dependencies, local development notes, credentials, state, and logs. `scripts/check-public-files.py` checks the tracked public file set, and the source ZIP uses that same set. When building an extracted source ZIP without Git, it uses the explicit list in that script.

Do not upload the entire working directory. The check catches common sensitive patterns and must be paired with review of the actual diff and images. Screenshots must use synthetic connection names, files, and credentials; see [screenshots/README.md](screenshots/README.md).
