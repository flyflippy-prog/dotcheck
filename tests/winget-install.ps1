#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Archive)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Installation tests require a disposable GitHub-hosted Windows runner'
}
if (-not $IsWindows) { throw 'Windows is required' }
$repo = Split-Path $PSScriptRoot
$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$root = Join-Path $env:RUNNER_TEMP ('dotcheck-winget-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$id = 'flyflippy.dotcheck'
$aliasPath = Join-Path $env:LOCALAPPDATA 'Microsoft/WinGet/Links/dotcheck.exe'
if (Test-Path -LiteralPath $aliasPath) { throw 'Existing dotcheck registration must not be replaced' }
$manualRegistration = [Environment]::GetEnvironmentVariable('DOTCHECK_TOOL_FILE', 'User')
$oldPath = $env:PATH
$server = $null
function Invoke-WinGet([string[]]$Arguments) {
    & $script:winget @Arguments --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw "WinGet failed ($LASTEXITCODE): $($Arguments -join ' ')" }
}
try {
    $existingWinGet = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $existingVersion = if ($existingWinGet) { [version]((& $existingWinGet.Source --version).Trim().TrimStart('v')) } else { [version]'0.0' }
    if ($existingVersion -lt [version]'1.12') {
        Install-Module Microsoft.WinGet.Client -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
        Import-Module Microsoft.WinGet.Client
        Repair-WinGetPackageManager -AllUsers -Force -Latest
        $env:PATH += ';' + (Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps')
    }
    $script:winget = (Get-Command winget -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    Invoke-WinGet @('--version')
    Invoke-WinGet @('settings', '--enable', 'LocalManifestFiles')
    $manifest = Join-Path $root 'manifest'
    $version = ([xml](Get-Content (Join-Path $repo 'src/dotcheck/dotcheck.csproj') -Raw)).Project.PropertyGroup.Version
    $generated = Join-Path $repo ('artifacts/winget-test-' + [guid]::NewGuid().ToString('N'))
    & (Join-Path $repo 'scripts/new-winget-manifest.ps1') -Archive $archivePath -PackageIdentifier $id `
        -RepositoryUrl 'https://github.com/flyflippy-prog/dotcheck' `
        -InstallerUrl "https://github.com/flyflippy-prog/dotcheck/releases/download/v$version/dotcheck-$version-win-x64.zip" `
        -OutputDirectory ([IO.Path]::GetRelativePath($repo, $generated))
    Copy-Item -LiteralPath $generated -Destination $manifest -Recurse
    Invoke-WinGet @('validate', '--manifest', $manifest)
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $python = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $server = Start-Process -FilePath $python -ArgumentList @(
        '-m', 'http.server', "$port", '--bind', '127.0.0.1', '--directory', ('"' + (Split-Path $archivePath) + '"')
    ) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root 'server-out.txt') -RedirectStandardError (Join-Path $root 'server-err.txt')
    $url = "http://127.0.0.1:$port/" + [uri]::EscapeDataString([IO.Path]::GetFileName($archivePath))
    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try { $null = Invoke-WebRequest $url -Method Head -TimeoutSec 2; $ready = $true; break }
        catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $ready) { throw 'Owned archive server did not start' }
    $installer = Join-Path $manifest "$id.installer.yaml"
    $content = Get-Content -LiteralPath $installer -Raw
    $content = $content -replace '(?m)^    InstallerUrl: .+$', "    InstallerUrl: '$url'"
    [IO.File]::WriteAllText($installer, $content)
    # Only the disposable installation test uses localhost; submitted manifests retain HTTPS release URLs.
    $previous = Join-Path $root 'previous'
    Copy-Item -LiteralPath $manifest -Destination $previous -Recurse
    Get-ChildItem $previous -File | ForEach-Object {
        [IO.File]::WriteAllText($_.FullName, ((Get-Content $_.FullName -Raw).Replace("PackageVersion: '$version'", "PackageVersion: '0.0.0'")))
    }
    $location = Join-Path $root 'installed tool Ω'
    Invoke-WinGet @('install', '--manifest', $previous, '--scope', 'user', '--location', $location, '--accept-package-agreements', '--accept-source-agreements')
    # Install detects the existing older portable registration and performs an upgrade.
    Invoke-WinGet @('install', '--manifest', $manifest, '--scope', 'user', '--location', $location, '--accept-package-agreements', '--accept-source-agreements')
    $inventory = & $script:winget list --id $id --exact --disable-interactivity --accept-source-agreements
    if ($LASTEXITCODE -ne 0 -or ($inventory -join "`n") -notmatch [regex]::Escape($version)) { throw 'Upgraded registration missing' }
    $executables = @(Get-ChildItem $location -Filter dotcheck.exe -File -Recurse)
    if ($executables.Count -ne 1 -or -not (Test-Path -LiteralPath $aliasPath)) { throw 'Installed executable or alias missing' }
    $installed = $executables[0].FullName
    foreach ($name in @('LICENSE', 'NOTICE', 'DOTNET-LICENSE.TXT', 'DOTNET-THIRD-PARTY-NOTICES.TXT')) {
        if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $installed) $name))) { throw "Missing installed notice: $name" }
    }
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH', 'User')
    $resolved = & (Get-Process -Id $PID).Path -NoProfile -Command '(Get-Command dotcheck -CommandType Application).Source'
    if ($LASTEXITCODE -ne 0 -or $resolved.Trim() -ne $aliasPath) { throw 'Fresh shell did not resolve the WinGet alias' }
    & (Join-Path $repo 'tests/published-smoke.ps1') -Tool $installed
    if ($LASTEXITCODE -ne 0) { throw 'Installed application smoke failed' }
    $foreign = Join-Path $root 'foreign'
    New-Item -ItemType Directory -Path $foreign | Out-Null
    $foreignCommand = Join-Path $foreign 'dotcheck.cmd'
    [IO.File]::WriteAllText($foreignCommand, '@exit /b 37')
    $foreignHash = (Get-FileHash $foreignCommand).Hash
    $env:PATH = "$foreign;" + $env:PATH
    Invoke-WinGet @('uninstall', '--id', $id, '--exact', '--scope', 'user')
    if ((Test-Path -LiteralPath $installed) -or (Test-Path -LiteralPath $aliasPath)) { throw 'Owned executable or alias survived uninstall' }
    if ((Get-FileHash $foreignCommand).Hash -ne $foreignHash) { throw 'Foreign command was changed' }
    if ([Environment]::GetEnvironmentVariable('DOTCHECK_TOOL_FILE', 'User') -ne $manualRegistration) { throw 'Manual installation marker was changed' }
    Invoke-WinGet @('install', '--manifest', $manifest, '--scope', 'user', '--location', $location, '--accept-package-agreements', '--accept-source-agreements')
    Invoke-WinGet @('uninstall', '--id', $id, '--exact', '--scope', 'user')
    'PASS WinGet install, synthetic-version upgrade, notices, installed smoke, command resolution, uninstall, foreign command preservation, reinstall'
} finally {
    $env:PATH = $oldPath
    if ($server -and -not $server.HasExited) { $server.Kill(); $server.WaitForExit() }
}
