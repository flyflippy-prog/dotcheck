#requires -Version 7.0
[CmdletBinding()]
param([string]$OutputDirectory, [switch]$ReusePublish)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$project = Join-Path $repo 'src/dotcheck/dotcheck.csproj'
$version = ([xml](Get-Content -LiteralPath $project -Raw)).Project.PropertyGroup.Version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Expected a three-part project version' }
if (-not $OutputDirectory) { $OutputDirectory = "artifacts/dotcheck-$version-win-x64" }
$output = [IO.Path]::GetFullPath((Join-Path $repo $OutputDirectory))
if (-not $output.StartsWith(([IO.Path]::GetFullPath($repo) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Package output must stay inside workspace'
}
$zip = $output + '.zip'
if (Test-Path -LiteralPath $zip) { throw 'Existing archive is preserved; choose a new output directory' }
if (-not $ReusePublish) {
    if (Test-Path -LiteralPath $output) { throw 'Existing output is preserved; choose a new output directory' }
    & dotnet publish $project -c Release -r win-x64 --self-contained true -p:PublishAot=false -o $output -v:q -m:1 /nodeReuse:false
    if ($LASTEXITCODE) { throw 'Publish failed' }
}
$exe = Join-Path $output 'dotcheck.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw 'Missing published executable' }
if ([Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileVersion -ne "$version.0") { throw 'Executable version does not match the project' }
if (Test-Path -LiteralPath (Join-Path $output 'evidence')) {
    throw 'Output contains local evidence; choose a fresh output directory'
}
$runtimeConfig = Get-Content (Join-Path $repo 'src/dotcheck/bin/Release/net10.0/win-x64/dotcheck.runtimeconfig.json') -Raw | ConvertFrom-Json
$runtimeVersion = ($runtimeConfig.runtimeOptions.includedFrameworks | Where-Object name -eq 'Microsoft.NETCore.App').version
$packageRoot = Join-Path $env:USERPROFILE ".nuget/packages/microsoft.netcore.app.runtime.win-x64/$runtimeVersion"
Copy-Item (Join-Path $packageRoot 'LICENSE.TXT') (Join-Path $output 'DOTNET-LICENSE.TXT')
Copy-Item (Join-Path $packageRoot 'THIRD-PARTY-NOTICES.TXT') (Join-Path $output 'DOTNET-THIRD-PARTY-NOTICES.TXT')
foreach ($name in @('LICENSE', 'NOTICE', 'README.md', 'AGENTS.md', 'CONTRIBUTING.md', 'CODE_OF_CONDUCT.md', 'SECURITY.md', 'CHANGELOG.md')) {
    Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $output
}
New-Item -ItemType Directory -Force (Join-Path $output 'docs') | Out-Null
foreach ($name in @('architecture.md', 'compatibility.md', 'development.md', 'installation.md', 'licensing.md', 'releasing.md', 'winget.md')) {
    Copy-Item -LiteralPath (Join-Path $repo "docs/$name") -Destination (Join-Path $output 'docs')
}
$sources = Get-ChildItem (Join-Path $repo 'src/dotcheck') -File | Sort-Object Name | ForEach-Object {
    @{ path = [IO.Path]::GetRelativePath($repo, $_.FullName).Replace('\', '/'); sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
}
$gitHead = & git -C $repo rev-parse --verify HEAD 2>$null
if ($LASTEXITCODE -ne 0) { $gitHead = $null }
@{
    version = $version; target = 'win-x64'; selfContained = $true; singleFile = $true
    runtimeVersion = $runtimeVersion; sdk = (& dotnet --version).Trim(); utc = [datetime]::UtcNow.ToString('o')
    gitHead = $gitHead; license = 'Apache-2.0'; sources = $sources
    localEvidenceIncluded = $false
    verification = 'Acceptance checks must run against this packaged executable before release'
} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $output 'build-metadata.json')
Get-ChildItem $output -File -Recurse | Where-Object Name -ne 'SHA256SUMS.txt' | Sort-Object FullName | ForEach-Object {
    (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetRelativePath($output, $_.FullName).Replace('\', '/')
} | Set-Content (Join-Path $output 'SHA256SUMS.txt')
Compress-Archive -LiteralPath $output -DestinationPath $zip
(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($zip) | Set-Content ($zip + '.sha256')
"PASS package=$output archive=$zip"
