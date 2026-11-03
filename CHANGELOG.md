# Changelog

Notable changes to CloudDock are documented here. Version numbers match the packaged app's `CFBundleShortVersionString`.

## [0.5.9] - 2026-11-03

### Fixed

- Read the workspace footer version from app bundle metadata. Version 0.5.8 previously displayed a hard-coded `0.5.7` even after a successful installation.
- Show a development label when running outside an app bundle instead of displaying an outdated release number.

### Documentation

- Add real app screenshots to the English and Chinese READMEs, with private identifiers and share data redacted.
- Require completed local installation and version verification in the test-development workflow.

## [0.5.8] - 2026-11-03

### Documentation and packaging

- Prepare an English default README and a Simplified Chinese README, with repository metadata and publishing instructions for `zealerFT/clouddock`.
- Add an MIT license and retain rclone's third-party notices.
- Exclude local development records, generated files, and credential data from the public source file set.
- Include both README languages and license information in release packages.
- Publish the first GitHub release with tagged source, an Apple Silicon DMG, app ZIP, source ZIP, and checksums.
- Build releases with GitHub Actions, keep a shared version file, and document development in the Git checkout.
- Remove local build paths from the distributable app binary.

### Fixed

- Allow the isolated S3 test server up to 60 seconds to start on a fresh CI runner and report its log on startup failure.

Version 0.5.7 was tagged during release setup; its CI run stopped before publishing installers. Version 0.5.8 is the first downloadable GitHub release.

## [0.5.7] - 2026-11-02

### Fixed

- Make the entire sidebar connection row clickable, including transparent whitespace in unselected rows.
- Apply the context menu to the full row and display the connection name above its actions.

## [0.5.6] - 2026-11-02

### Added

- Google Cloud Storage V4 download sharing with service-account signing, configurable expiry, and QR codes.
- Local fake-gcs-server direct download links, explicitly labeled as having no enforced expiry.

### Fixed

- Normalize previously saved local Google endpoints at request time, including missing `/storage/v1/` paths or trailing slashes, so transfers and deletion use the correct API.
- Extend regression checks to old endpoint formats, special-character filenames, share downloads, and deletion.

## Earlier development

The 0.1–0.5 series introduced the native multi-provider workspace, drag-and-drop transfers, overwrite prompts, previews, download sharing, local operation history, optional Keychain storage, and paginated browsing. Subsequent fixes addressed connection persistence and editing, startup navigation, MinIO object-name decoding, LocalStack routing, and local GCS listing.

Earlier entries are summarized because this repository was prepared after those development iterations; they are not a claim of previously published GitHub releases.
