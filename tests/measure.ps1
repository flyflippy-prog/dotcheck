#requires -Version 7.0
param([string]$Tool=(Join-Path $PSScriptRoot '../artifacts/dotcheck-1.0.0-win-x64/dotcheck.exe'),[int]$Repetitions=7)
$ErrorActionPreference='Stop';$Tool=[IO.Path]::GetFullPath($Tool)
$root=Join-Path ([IO.Path]::GetTempPath()) ('dotcheck-measure-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory $root)
$ps=(Get-Process -Id $PID).Path;$baseline=Join-Path $PSScriptRoot '../reference/powershell/dotcheck.ps1'
$small=Join-Path $root 'small.trx';Copy-Item (Join-Path $PSScriptRoot 'fixtures/passed.trx') $small
$large=Join-Path $root 'large.trx';$builder=[Text.StringBuilder]::new();[void]$builder.Append('<TestRun><Results>')
foreach($i in 1..10000){[void]$builder.Append("<UnitTestResult testName='Synthetic.Test$i' outcome='Passed' duration='00:00:00.001'/>")}
[void]$builder.Append("</Results><ResultSummary outcome='Completed'><Counters total='10000' passed='10000' failed='0' notExecuted='0'/></ResultSummary></TestRun>");[IO.File]::WriteAllText($large,$builder.ToString())
$journal=Join-Path $root 'journal.jsonl';$builder.Clear()|Out-Null
foreach($i in 1..1000){$id=[guid]::NewGuid().ToString('D');$time='2026-10-20T00:00:00Z';[void]$builder.AppendLine((@{schemaVersion=1;event='started';runId=$id;startedUtc=$time;verb='build'}|ConvertTo-Json -Compress));[void]$builder.AppendLine((@{schemaVersion=1;event='finished';runId=$id;startedUtc=$time;verb='build';result=@{exit=0;status='pass';outcome='passed'}}|ConvertTo-Json -Depth 5 -Compress))}
[IO.File]::WriteAllText($journal,$builder.ToString())
$sim=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Simulator/bin/Release/net10.0/dotnet.exe'))
$oldPath=$env:PATH;$oldMode=$env:DOTCHECK_SIM_CASE;$oldLegacy=$env:DOTCHECK_TEST_CASE
$all=[Collections.Generic.List[object]]::new()
function Sample([string]$File,[string[]]$Arguments){
    $p=[Diagnostics.Process]::new();$p.StartInfo=[Diagnostics.ProcessStartInfo]::new($File);$p.StartInfo.UseShellExecute=$false;$p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
    foreach($a in $Arguments){$p.StartInfo.ArgumentList.Add($a)}
    $sw=[Diagnostics.Stopwatch]::StartNew();[void]$p.Start();$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
    $peak=0L
    while(-not $p.WaitForExit(2)){
        try{$p.Refresh();$peak=[math]::Max($peak,$p.PeakWorkingSet64)}catch{}
        if($sw.ElapsedMilliseconds -gt 30000){$p.Kill($true);throw 'measurement timeout'}
    };$sw.Stop()
    if($p.ExitCode -ne 0){throw 'measurement workload failed'}
    $null=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult()
    if($peak -eq 0){throw 'No live memory sample; measurement invalid'}
    $value=@{ms=$sw.Elapsed.TotalMilliseconds;peakRootBytes=$peak};$p.Dispose();return $value
}
try{
    $env:PATH=(Split-Path $sim)+[IO.Path]::PathSeparator+$oldPath;$env:DOTCHECK_SIM_CASE='quick';$env:DOTCHECK_TEST_CASE='build'
    $workloads=@{startup=@('-Help');small=@('-Path',$small,'-Json');large=@('-Path',$large,'-Json');journal=@('-LastRun','-JournalPath',$journal,'-Json');runner=@('-Build','-Project',(Join-Path $PSScriptRoot 'Simulator/Simulator.csproj'),'-Json')}
    foreach($workload in @('startup','small','large','journal','runner')){
        foreach($variant in @('powershell','native')){
            $file=if($variant -eq 'native'){$Tool}else{$ps};$arguments=if($variant -eq 'native'){$workloads[$workload]}else{@('-NoProfile','-File',$baseline)+$workloads[$workload]}
            $first=Sample $file $arguments;$warm=@(foreach($i in 1..$Repetitions){Sample $file $arguments})
            $sorted=@($warm.ms|Sort-Object);$row=@{workload=$workload;variant=$variant;firstLaunch=$first;warm=$warm;warmMedianMs=$sorted[[int][math]::Floor($sorted.Count/2)];warmP95Ms=$sorted[[math]::Ceiling(.95*$sorted.Count)-1]};$all.Add($row)
        }
    }
    $direct=@(foreach($i in 1..$Repetitions){Sample $sim @('build','synthetic')})
    $result=@{utc=[datetime]::UtcNow.ToString('o');os=[Environment]::OSVersion.ToString();architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();sdk='10.0.402';repetitions=$Repetitions;temperature='first measured launch and warm; OS cache not flushed; no true cold-cache claim';memory='PeakWorkingSet64 sampled while alive at approximately 2ms intervals; root only, excludes worker/native descendants';smallBytes=(Get-Item $small).Length;largeBytes=(Get-Item $large).Length;journalBytes=(Get-Item $journal).Length;journalRuns=1000;largeTests=10000;publishBytes=(Get-Item $Tool).Length;measurements=$all;directSimulator=$direct;fixtureRoot=$root}
    $target=Join-Path $PSScriptRoot '../evidence/measurements.json';$result|ConvertTo-Json -Depth 12|Set-Content $target
    "PASS measurementWorkloads=$($all.Count) repetitions=$Repetitions evidence=$root result=$target"
}finally{$env:PATH=$oldPath;$env:DOTCHECK_SIM_CASE=$oldMode;$env:DOTCHECK_TEST_CASE=$oldLegacy}
