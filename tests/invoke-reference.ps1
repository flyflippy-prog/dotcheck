#requires -Version 7.0
param([Parameter(Mandatory)][string]$Tool,[Parameter(Mandatory)][string]$ArgumentsPath)
$ErrorActionPreference='Stop'
$bound=Get-Content -LiteralPath $ArgumentsPath -Raw|ConvertFrom-Json -AsHashtable
if($bound.ContainsKey('DotnetArgs')){$bound.DotnetArgs=[string[]]$bound.DotnetArgs}
if($bound.ContainsKey('Path')){$bound.Path=[string[]]$bound.Path}
& $Tool @bound
exit $LASTEXITCODE
