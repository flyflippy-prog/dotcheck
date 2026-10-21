#requires -Version 7.0
[CmdletBinding()]
param([switch]$NativeAot, [switch]$RequireFileSymlink, [string]$PackageOutputDirectory)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'Verification requires Windows x64'
}

$repo = Split-Path $PSScriptRoot
if ($NativeAot -and $PackageOutputDirectory) { throw 'Release packaging currently supports managed publishing only' }
$variant = if ($NativeAot) { 'aot' } else { 'managed' }
$output = Join-Path $repo ("artifacts/verify-$variant-" + [guid]::NewGuid().ToString('N'))
if ($PackageOutputDirectory) { $output = [IO.Path]::GetFullPath((Join-Path $repo $PackageOutputDirectory)) }
$pwsh = (Get-Process -Id $PID).Path

function Invoke-Checked([string]$File, [string[]]$Arguments) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Verification command failed: $File (exit $LASTEXITCODE)" }
}

Push-Location $repo
try {
    $manifest = Get-Content -LiteralPath 'reference/manifest.json' -Raw | ConvertFrom-Json
    foreach ($file in $manifest.files) {
        if ((Get-FileHash -LiteralPath $file.relativePath -Algorithm SHA256).Hash -ne $file.sha256) {
            throw "Captured baseline hash mismatch: $($file.relativePath)"
        }
    }
    Write-Output 'PASS captured baseline hashes'

    Invoke-Checked dotnet @('build', 'dotcheck.slnx', '-c', 'Release', '-m:1', '/nodeReuse:false')
    Invoke-Checked dotnet @('format', 'whitespace', 'dotcheck.slnx', '--verify-no-changes', '--no-restore')
    Invoke-Checked (Join-Path $repo 'tests/dotcheck.tests/bin/Release/net10.0/dotcheck.tests.exe') @('tests/fixtures')
    foreach ($project in @('tests/Simulator/Simulator.csproj', 'tests/CancelGate/CancelGate.csproj')) {
        Invoke-Checked dotnet @('build', $project, '-c', 'Release', '-m:1', '/nodeReuse:false')
    }
    if ($PackageOutputDirectory) {
        Invoke-Checked $pwsh @('-NoProfile', '-File', 'scripts/package.ps1', '-OutputDirectory', $PackageOutputDirectory)
    } else {
        Invoke-Checked dotnet @('publish', 'src/dotcheck/dotcheck.csproj', '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', "-p:PublishAot=$($NativeAot.IsPresent.ToString().ToLowerInvariant())", '-o', $output, '-m:1', '/nodeReuse:false')
    }
    $tool = Join-Path $output 'dotcheck.exe'
    foreach ($gate in @('legacy-harness', 'differential', 'process-gates', 'contract-regressions', 'published-smoke')) {
        Write-Output "Running $gate"
        Invoke-Checked $pwsh @('-NoProfile', '-File', "tests/$gate.ps1", '-Tool', $tool)
    }

    $cleanup = @(Invoke-Checked $pwsh @('-NoProfile', '-File', 'tests/cleanup-gates.ps1', '-Tool', $tool))
    $cleanup | Write-Output
    if (($cleanup -join "`n") -match 'fileSymlink=blocked:') {
        if ($RequireFileSymlink) { throw 'Release requires a passing live file-symlink cleanup check' }
        Write-Warning 'File-symlink gate BLOCKED by privileges; full cleanup acceptance remains open.'
        if ($env:GITHUB_ACTIONS -eq 'true') {
            Write-Output '::warning::File-symlink gate blocked by privileges; this run does not establish full release acceptance.'
        }
    }

    Invoke-Checked (Join-Path $repo 'tests/CancelGate/bin/Release/net10.0/CancelGate.exe') @(
        $tool,
        (Join-Path $repo 'tests/Simulator/bin/Release/net10.0/dotnet.exe'),
        (Join-Path $repo 'tests/Simulator/Simulator.csproj'),
        (Join-Path $output 'cancellation.txt')
    )
    Write-Output "PASS executed verification gates ($variant); local output=$output"
    Write-Output 'Not exercised by this script: actual MTP, other platforms/architectures, real PATH rollout, Sandbox, benchmarks, external release. Project license: Apache-2.0.'
} finally {
    Pop-Location
}
