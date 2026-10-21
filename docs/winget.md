# WinGet distribution

The WinGet manifest uses a ZIP containing the Windows x64 executable.
The installation instructions select user scope. The ZIP includes documentation,
LICENSE, NOTICE, and the Microsoft .NET license/third-party notices. It is self-contained, so the
manifest does not require an installed runtime. An SDK is needed only for Build/Run.

WinGet supports ZIP archives with `NestedInstallerType: portable` and an explicit
executable path/command alias. See the [Microsoft manifest specification](https://github.com/microsoft/winget-pkgs/blob/master/doc/manifest/schema/1.12.0/installer.md).
WinGet's [portable installation implementation](https://github.com/microsoft/winget-cli/blob/master/src/AppInstallerCLICore/Workflows/PortableFlow.cpp)
retains archive contents; installation tests must confirm that all four
license/notice files remain present on the target machine.

## Required release information

Before generating the final manifest, confirm:

- The repository is `https://github.com/flyflippy-prog/dotcheck`.
- The package identifier is `flyflippy.dotcheck`; the publisher display name is
  flyflippy. Check for an existing package or submission before opening a PR.
- A published, version-specific GitHub ZIP URL and the matching local archive.
- Successful clean-machine installation, command resolution, upgrade, and removal.

Use `flyflippy.dotcheck` in install and uninstall commands.

## Generate manifests

Publish the verified ZIP from the draft GitHub Release, then run:

```powershell
pwsh -NoProfile -File .\scripts\new-winget-manifest.ps1 `
  -Archive .\artifacts\dotcheck-1.0.0-win-x64.zip `
  -PackageIdentifier flyflippy.dotcheck `
  -RepositoryUrl https://github.com/flyflippy-prog/dotcheck `
  -InstallerUrl https://github.com/flyflippy-prog/dotcheck/releases/download/v1.0.0/dotcheck-1.0.0-win-x64.zip
```

The script reads the version, architecture, and executable path from the actual
ZIP and computes its SHA-256. It requires project/runtime license materials and
rejects evidence-bearing packages and unversioned download URLs. It generates
version, installer, and en-US locale manifests under `artifacts/winget`, using
schema 1.12.0. Existing output is never overwritten.

The installer declares a portable ZIP, the `dotcheck` alias, and
uninstall-before-upgrade behavior. Portable manifests omit `Scope`; choose
`--scope user` when installing. WinGet owns registration and removal. Do not
configure installer switches that call dotcheck's manual `-Install` or `-Uninstall`;
mixing both mechanisms leaves ambiguous PATH ownership.

## Validate and test

```powershell
winget validate --manifest .\artifacts\winget
```

Download the published asset into a fresh directory and compare its SHA-256 with
`InstallerSha256`. A local archive hash does not verify the uploaded download.
Then test in Windows Sandbox or a disposable Windows x64 VM, with local manifests
enabled in that environment:

```powershell
winget settings --enable LocalManifestFiles
winget install --manifest .\artifacts\winget --scope user
Get-Command dotcheck -All
dotcheck -Help
dotcheck -Path .\synthetic-passed.trx -Json
```

Check installed license files, Apps & Features registration, behavior without an
installed runtime, spaces in paths, and an existing unrelated command. Check that
a fresh shell resolves the intended copy. Test upgrade from a prior disposable
test version, then removal:

```powershell
winget uninstall --id flyflippy.dotcheck --exact
```

Verify owned files/aliases are removed while unrelated PATH entries, commands,
and reports remain intact. Do not run installation tests against a working copy.

The manually dispatched `WinGet installation` workflow runs portable package
installation tests on a disposable GitHub-hosted Windows runner. It validates
the generated manifests, serves the candidate archive over loopback, and checks
installation, a synthetic-version upgrade, installed application behavior,
license retention, command resolution, removal, and reinstallation. Its temporary
localhost manifests and synthetic prior version are never submitted. The runner
includes an SDK; this does not replace a separate check on a machine without .NET.

## Submit

Copy the validated manifests into the community repository structure:
`manifests/<publisher-initial>/<publisher>/<package>/<version>/`.
Follow [Microsoft's submission guide](https://learn.microsoft.com/en-us/windows/package-manager/package/manifest).
Submission is a separate PR to `microsoft/winget-pkgs`; these workflows do not
submit it automatically. Never replace a published ZIP in place.
