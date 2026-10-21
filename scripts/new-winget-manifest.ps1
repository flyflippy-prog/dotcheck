#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$')][string]$PackageIdentifier,
    [Parameter(Mandatory)][uri]$RepositoryUrl,
    [Parameter(Mandatory)][uri]$InstallerUrl,
    [string]$OutputDirectory = 'artifacts/winget'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$repository = $RepositoryUrl.AbsoluteUri.TrimEnd('/')
if ($repository -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Use the confirmed public GitHub repository URL' }
$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$output = [IO.Path]::GetFullPath((Join-Path $repo $OutputDirectory))
if (-not $output.StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest output must stay inside workspace' }
if (Test-Path -LiteralPath $output) { throw 'Choose a fresh manifest output directory' }
$zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $executables = @($zip.Entries | Where-Object { $_.FullName -match '(^|/)dotcheck\.exe$' })
    if ($executables.Count -ne 1) { throw 'Expected exactly one dotcheck.exe in the ZIP' }
    $relative = $executables[0].FullName
    $root = $relative.Substring(0, $relative.Length - 'dotcheck.exe'.Length)
    function Read-Entry([string]$Name) {
        $entry = $zip.GetEntry($root + $Name)
        if (-not $entry) { throw "Missing package file: $Name" }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    $metadata = Read-Entry 'build-metadata.json' | ConvertFrom-Json
    $version = $metadata.version
    if ($version -notmatch '^\d+\.\d+\.\d+$' -or $metadata.target -ne 'win-x64' -or -not $metadata.selfContained -or $metadata.localEvidenceIncluded -or $metadata.license -cne 'Apache-2.0') {
        throw 'Expected a self-contained Windows x64 Apache-2.0 package without local evidence'
    }
    if ($InstallerUrl.AbsoluteUri -cnotmatch ('^' + [regex]::Escape($repository) + '/releases/download/(v?' + [regex]::Escape($version) + ')/[^/?#]+\.zip$')) {
        throw 'Installer URL must name this versioned GitHub ZIP asset, without latest links or query parameters'
    }
    $tag = $Matches[1]
    foreach ($name in @('LICENSE', 'NOTICE', 'DOTNET-LICENSE.TXT', 'DOTNET-THIRD-PARTY-NOTICES.TXT')) { [void](Read-Entry $name) }
    if (@($zip.Entries | Where-Object { $_.FullName -match '(^|/)(evidence|private|TestResults)/|\.(jsonl|log|key|pem|pfx|trx)$' }).Count) { throw 'Archive contains private or generated evidence' }
} finally { $zip.Dispose() }
$hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
function Quote-Yaml([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }
$id = Quote-Yaml $PackageIdentifier
$v = Quote-Yaml $version
$url = Quote-Yaml $InstallerUrl.AbsoluteUri
$path = Quote-Yaml $relative
$packageUrl = Quote-Yaml $repository
$licenseUrl = Quote-Yaml "$repository/blob/$tag/LICENSE"
$releaseUrl = Quote-Yaml "$repository/releases/tag/$tag"
$files = @{}
$files["$PackageIdentifier.yaml"] = @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.version.1.12.0.schema.json
PackageIdentifier: $id
PackageVersion: $v
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.12.0
"@
$files["$PackageIdentifier.installer.yaml"] = @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.installer.1.12.0.schema.json
PackageIdentifier: $id
PackageVersion: $v
InstallerType: zip
NestedInstallerType: portable
UpgradeBehavior: uninstallPrevious
Commands:
  - dotcheck
Installers:
  - Architecture: x64
    InstallerUrl: $url
    InstallerSha256: $hash
    NestedInstallerFiles:
      - RelativeFilePath: $path
        PortableCommandAlias: dotcheck
ManifestType: installer
ManifestVersion: 1.12.0
"@
$files["$PackageIdentifier.locale.en-US.yaml"] = @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.defaultLocale.1.12.0.schema.json
PackageIdentifier: $id
PackageVersion: $v
PackageLocale: en-US
Publisher: flyflippy
PackageName: dotcheck
PackageUrl: $packageUrl
License: Apache-2.0
LicenseUrl: $licenseUrl
Copyright: Copyright (c) 2026 flyflippy
ShortDescription: Bounded .NET build/test diagnostics and TRX report inspection.
Description: Self-contained .NET 10 CLI for Windows x64. Building or testing projects requires an appropriate .NET SDK.
Moniker: dotcheck
Tags:
  - dotnet
  - cli
  - trx
  - testing
ReleaseNotesUrl: $releaseUrl
ManifestType: defaultLocale
ManifestVersion: 1.12.0
"@
New-Item -ItemType Directory -Path $output | Out-Null
foreach ($item in $files.GetEnumerator()) { [IO.File]::WriteAllText((Join-Path $output $item.Key), $item.Value.TrimEnd() + "`n", [Text.UTF8Encoding]::new($false)) }
"PASS generated manifests=$output; validate the manifests and published download before submission"
