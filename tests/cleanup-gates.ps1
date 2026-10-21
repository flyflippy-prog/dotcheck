#requires -Version 7.0
param([string]$Tool=(Join-Path $PSScriptRoot '../artifacts/dotcheck-1.0.0-win-x64/dotcheck.exe'))
$ErrorActionPreference='Stop';$Tool=[IO.Path]::GetFullPath($Tool)
$root=Join-Path ([IO.Path]::GetTempPath()) ('dotcheck-cleanup-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory $root)
$target=Join-Path $root 'target';[void](New-Item -ItemType Directory (Join-Path $target 'nested') -Force)
Set-Content (Join-Path $target 'retain.trx') 'synthetic';Set-Content (Join-Path $target 'nested/retain.trx') 'synthetic'
$junction=Join-Path $root 'junction';New-Item -ItemType Junction -Path $junction -Target $target|Out-Null
$checks=0
foreach($directory in @($junction,(Join-Path $junction 'nested'))){
    $text=& $Tool -Clean -ResultsDirectory $directory -KeepReports 0 -Json;$exitCode=$LASTEXITCODE;$v=$text|ConvertFrom-Json
    if($exitCode -ne 2 -or $v.error -ne 'unsafe_run_store'){throw 'Junction cleanup was not rejected'};$checks++
}
if(-not(Test-Path (Join-Path $target 'retain.trx')) -or -not(Test-Path (Join-Path $target 'nested/retain.trx'))){throw 'Reparse target modified'};$checks++
$symbolicStatus='passed'
try{New-Item -ItemType SymbolicLink -Path (Join-Path $target 'link.trx') -Target (Join-Path $target 'retain.trx') -ErrorAction Stop|Out-Null}
catch{
    if($_.Exception.Message -match 'privilege|administrator|denied'){$symbolicStatus='blocked: file symlink creation requires Administrator or Developer Mode'}else{throw}
}
if($symbolicStatus -eq 'passed'){
    $v=(& $Tool -Clean -ResultsDirectory $target -KeepReports 0 -Json)|ConvertFrom-Json
    if($v.skipped -ne 1){throw 'File reparse was not skipped'};$checks++
}
"PASS junctionChecks=$checks fileSymlink=$symbolicStatus evidence=$root"
