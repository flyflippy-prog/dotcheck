#requires -Version 7.0
param([string]$Tool=(Join-Path $PSScriptRoot '../artifacts/dotcheck-1.0.0-win-x64/dotcheck.exe'))
$ErrorActionPreference='Stop';$Tool=[IO.Path]::GetFullPath($Tool)
$root=Join-Path ([IO.Path]::GetTempPath()) ('dotcheck-contract-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory $root)
$baseline=Join-Path $PSScriptRoot '../reference/powershell/dotcheck.ps1';$sim=Join-Path $PSScriptRoot 'Simulator/bin/Release/net10.0/dotnet.exe'
$oldPath=$env:PATH;$oldMode=$env:DOTCHECK_SIM_CASE;$ps=(Get-Process -Id $PID).Path
$evidence=[Collections.Generic.List[object]]::new();$checks=0
function Compare-Contract([string]$Name,[string[]]$Arguments,[int]$Before,[int]$After){
    # pwsh -File cannot marshal a String[] whose first element resembles a parameter.
    # Splat typed synthetic values in a separate reference host; never rewrite the captured source.
    $bound=@{};for($i=0;$i -lt $Arguments.Count;$i++){$key=$Arguments[$i].TrimStart('-');if($key -in @('Json','Build','Run','LastRun')){$bound[$key]=$true}else{$bound[$key]=$Arguments[++$i]}}
    if($bound.ContainsKey('DotnetArgs')){$bound.DotnetArgs=@($bound.DotnetArgs)}
    $argumentsPath=Join-Path $root ([guid]::NewGuid().ToString('N')+'.args.json');$bound|ConvertTo-Json -Depth 5|Set-Content $argumentsPath
    $left=& $ps -NoProfile -File (Join-Path $PSScriptRoot 'invoke-reference.ps1') -Tool $baseline -ArgumentsPath $argumentsPath;$leftExit=$LASTEXITCODE
    $right=& $Tool @Arguments;$rightExit=$LASTEXITCODE
    $evidence.Add(@{name=$Name;before=@{exit=$leftExit;payload=($left|ConvertFrom-Json -AsHashtable)};after=@{exit=$rightExit;payload=($right|ConvertFrom-Json -AsHashtable)}})
    if($leftExit -ne $Before -or $rightExit -ne $After){throw "FAIL contract regression $Name"};$script:checks++
}
try{
    $env:PATH=[IO.Path]::GetFullPath((Split-Path $sim))+[IO.Path]::PathSeparator+$oldPath
    $env:DOTCHECK_SIM_CASE='compilerzero'
    Compare-Contract 'compiler error with native success' @('-Build','-Project',(Join-Path $PSScriptRoot 'Simulator/Simulator.csproj'),'-Json') 0 1
    $env:DOTCHECK_SIM_CASE='quick'
    Compare-Contract 'MSBuild managed property override' @('-Build','-Project',(Join-Path $PSScriptRoot 'Simulator/Simulator.csproj'),'-DotnetArgs','-p:Configuration=Release','-Json') 0 2
    $id=[guid]::NewGuid().ToString('D');$journal=Join-Path $root 'contradiction.jsonl'
    @(@{event='started';runId=$id;startedUtc='2026-10-20T00:00:00Z';verb='build'},@{event='finished';runId=$id;startedUtc='2026-10-20T00:00:00Z';result=@{exit=0;status='pass';outcome='aborted'}})|ForEach-Object{$_|ConvertTo-Json -Depth 6 -Compress}|Set-Content $journal
    Compare-Contract 'contradictory historical success' @('-LastRun','-JournalPath',$journal,'-Json') 0 2
    $evidence|ConvertTo-Json -Depth 20|Set-Content (Join-Path $root 'before-after.json')
    "PASS contractChecks=$checks evidence=$root"
}finally{$env:PATH=$oldPath;$env:DOTCHECK_SIM_CASE=$oldMode}
