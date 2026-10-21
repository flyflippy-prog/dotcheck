#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Archive, [switch]$AllowLocalInstallation)
$ErrorActionPreference = 'Stop'
$hosted = $env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted'
if (-not $hosted -and -not $AllowLocalInstallation) {
    throw 'Use a disposable GitHub-hosted runner or explicitly authorize local installation with AllowLocalInstallation'
}
if (-not $IsWindows) { throw 'Windows is required' }
$repo = Split-Path $PSScriptRoot
$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$temporaryRoot = if ($hosted) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$root = Join-Path $temporaryRoot ('dotcheck-winget-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$id = 'flyflippy.dotcheck'
$aliasPath = Join-Path $env:LOCALAPPDATA 'Microsoft/WinGet/Links/dotcheck.exe'
if (Test-Path -LiteralPath $aliasPath) { throw 'Existing dotcheck registration must not be replaced' }
$uninstallKey = 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall'
if ((Test-Path $uninstallKey) -and @(Get-ItemProperty "$uninstallKey/*" | Where-Object DisplayName -eq dotcheck).Count) {
    throw 'An existing dotcheck installation must not be replaced by installation tests'
}
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
        if (-not $hosted) { throw 'Install WinGet 1.12 or later before running local tests' }
        $bootstrap = Join-Path $root 'winget-bootstrap'
        New-Item -ItemType Directory -Path $bootstrap | Out-Null
        $release = 'https://github.com/microsoft/winget-cli/releases/download/v1.29.380'
        Invoke-WebRequest "$release/DesktopAppInstaller_Dependencies.zip" -OutFile (Join-Path $bootstrap 'dependencies.zip')
        Expand-Archive -LiteralPath (Join-Path $bootstrap 'dependencies.zip') -DestinationPath (Join-Path $bootstrap 'dependencies')
        $dependencies = @(Get-ChildItem (Join-Path $bootstrap 'dependencies/x64') -Filter '*.msix' -File -Recurse | Select-Object -ExpandProperty FullName)
        $dependencies += @(Get-ChildItem (Join-Path $bootstrap 'dependencies/x64') -Filter '*.appx' -File -Recurse | Select-Object -ExpandProperty FullName)
        Invoke-WebRequest "$release/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" -OutFile (Join-Path $bootstrap 'winget.msixbundle')
        Add-AppxPackage -Path (Join-Path $bootstrap 'winget.msixbundle') -DependencyPath $dependencies -ForceApplicationShutdown
        $env:PATH += ';' + (Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps')
    }
    $script:winget = (Get-Command winget -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    Invoke-WinGet @('--version')
    if ($hosted) { Invoke-WinGet @('settings', '--enable', 'LocalManifestFiles') }
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
    $server = Start-Job -ArgumentList $archivePath, $port -ScriptBlock {
        param($archive, $port)
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
        $listener.Start()
        try {
            while ($true) {
                if (-not $listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 5000
                    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
                    $request = $reader.ReadLine()
                    if (-not $request) { continue }
                    while ($reader.ReadLine()) { }
                    $parts = $request.Split(' ')
                    $valid = $parts[0] -in @('GET', 'HEAD') -and [uri]::UnescapeDataString($parts[1]) -eq ('/' + [IO.Path]::GetFileName($archive))
                    $length = if ($valid) { (Get-Item -LiteralPath $archive).Length } else { 0 }
                    $status = if ($valid) { '200 OK' } else { '404 Not Found' }
                    $headers = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Length: $length`r`nConnection: close`r`n`r`n")
                    $stream.Write($headers, 0, $headers.Length)
                    if ($valid -and $parts[0] -eq 'GET') {
                        $file = [IO.File]::OpenRead($archive)
                        try { $file.CopyTo($stream) } finally { $file.Dispose() }
                    }
                } catch [IO.IOException] {
                    # A downloader may probe or abandon a connection before issuing a request.
                } finally { $client.Dispose() }
            }
        } finally { $listener.Stop() }
    }
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
    $previousExecutables = @(Get-ChildItem $location -Filter dotcheck.exe -File -Recurse)
    if ($previousExecutables.Count -ne 1) { throw 'Initial portable executable missing' }
    & $previousExecutables[0].FullName -Path (Join-Path $repo 'tests/fixtures/passed.trx') -Json
    if ($LASTEXITCODE -ne 0) { throw 'Initial installation in Unicode path failed' }
    Invoke-WinGet @('upgrade', '--manifest', $manifest, '--accept-package-agreements', '--accept-source-agreements')
    $registration = @(Get-ItemProperty 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall/*' | Where-Object { $_.WinGetPackageIdentifier -eq $id })
    if ($registration.Count -ne 1 -or $registration[0].DisplayVersion -ne $version) { throw 'Upgraded registration missing' }
    $upgradedLocation = [IO.Path]::GetFullPath($registration[0].InstallLocation)
    $portableRoot = Join-Path $env:LOCALAPPDATA 'Microsoft/WinGet/Packages'
    if ($upgradedLocation -ne $location -and -not $upgradedLocation.StartsWith(($portableRoot + '\' + $id + '_'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected upgraded installation location' }
    if ($upgradedLocation -ne $location -and (Test-Path -LiteralPath $previousExecutables[0].FullName)) { throw 'Previous executable survived uninstall-before-upgrade' }
    $executables = @(Get-ChildItem $upgradedLocation -Filter dotcheck.exe -File -Recurse)
    if ($executables.Count -ne 1) { throw 'Installed executable missing' }
    $installed = $executables[0].FullName
    foreach ($name in @('LICENSE', 'NOTICE', 'DOTNET-LICENSE.TXT', 'DOTNET-THIRD-PARTY-NOTICES.TXT')) {
        if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $installed) $name))) { throw "Missing installed notice: $name" }
    }
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH', 'User')
    $resolved = & (Get-Process -Id $PID).Path -NoProfile -Command '(Get-Command dotcheck -CommandType Application).Source'
    if ($LASTEXITCODE -ne 0 -or $resolved.Trim() -notin @($aliasPath, $installed)) { throw 'Fresh shell did not resolve the WinGet command' }
    & (Join-Path $repo 'tests/published-smoke.ps1') -Tool $installed
    if ($LASTEXITCODE -ne 0) { throw 'Installed application smoke failed' }
    $foreign = Join-Path $root 'foreign'
    New-Item -ItemType Directory -Path $foreign | Out-Null
    $foreignCommand = Join-Path $foreign 'dotcheck.cmd'
    [IO.File]::WriteAllText($foreignCommand, '@exit /b 37')
    $foreignHash = (Get-FileHash $foreignCommand).Hash
    $env:PATH = "$foreign;" + $env:PATH
    # Local manifests have no community-source correlation until the package is indexed.
    Invoke-WinGet @('uninstall', '--name', 'dotcheck', '--exact', '--scope', 'user')
    if ((Test-Path -LiteralPath $installed) -or (Test-Path -LiteralPath $aliasPath)) { throw 'Owned executable or alias survived uninstall' }
    if ((Get-FileHash $foreignCommand).Hash -ne $foreignHash) { throw 'Foreign command was changed' }
    if ([Environment]::GetEnvironmentVariable('DOTCHECK_TOOL_FILE', 'User') -ne $manualRegistration) { throw 'Manual installation marker was changed' }
    Invoke-WinGet @('install', '--manifest', $manifest, '--scope', 'user', '--location', $location, '--accept-package-agreements', '--accept-source-agreements')
    Invoke-WinGet @('uninstall', '--name', 'dotcheck', '--exact', '--scope', 'user')
    'PASS WinGet install, synthetic-version upgrade, notices, installed smoke, command resolution, uninstall, foreign command preservation, reinstall'
} finally {
    $env:PATH = $oldPath
    if ($server) { Stop-Job $server; Remove-Job $server }
}
