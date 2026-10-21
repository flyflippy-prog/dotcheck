# Releasing dotcheck

## Version and verification

Update the version in the project, Help, and new journal records together. Journal
schemaVersion is independent of the application version. Update CHANGELOG.md and
`.github/release-notes.md` for the release.

Use a clean source revision and a new package directory:

```powershell
pwsh -NoProfile -File .\scripts\verify.ps1 -RequireFileSymlink `
  -PackageOutputDirectory artifacts/dotcheck-1.0.0-win-x64
```

This packages the managed Windows x64 executable and tests that binary. Release
verification fails if the live file-symlink check is blocked. Test clean-machine
installation, command resolution, upgrade, and removal before publishing.

## Package review

The ZIP must contain:

- The verified dotcheck.exe and current user/developer documentation.
- dotcheck LICENSE and NOTICE.
- DOTNET-LICENSE.TXT and DOTNET-THIRD-PARTY-NOTICES.TXT from the bundled runtime pack.
- build-metadata.json with version, source revision, SDK/runtime versions, and SPDX.
- SHA256SUMS.txt covering the payload, plus the external ZIP `.sha256` file.

Compare the archive contents and hashes after extraction. Source fixtures,
internal reports, raw logs, journals, credentials, and IDE files do not belong in
a release archive. Preserve third-party notices; do not replace them with Apache-2.0.

## GitHub Release

Create and push a `vMAJOR.MINOR.PATCH` tag matching the project version.
`.github/workflows/release.yml` checks the tag, builds the managed package, runs
acceptance checks, uploads the ZIP/checksum, and creates a draft GitHub Release.
It also tests the portable ZIP with WinGet on the disposable build runner before
uploading release assets.
An existing empty draft can be populated. Published releases and existing assets
are preserved. Only the draft job has `contents: write`.

Review the draft's notes, source revision, assets, and checksums before publishing.
Download the published ZIP and verify its hash before preparing WinGet manifests.
Do not replace published assets in place.

## WinGet

Follow [winget.md](winget.md) to generate and validate portable ZIP manifests and
exercise install/upgrade/uninstall in a disposable Windows environment. Submission
to microsoft/winget-pkgs is separate from publishing the GitHub Release.

Signing, other platforms/architectures, and changes to installation ownership
require their own distribution tests. [licensing.md](licensing.md) describes
project and runtime license materials.
