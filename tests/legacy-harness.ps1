#requires -Version 7.0
# Adapted from reference/powershell/dotcheck.tests.ps1 (SHA-256 in reference/manifest.json).
# All 59 scenarios retained; native invocation and explicit owned-temp working directories.
[CmdletBinding()]
param([string]$Tool = (Join-Path $PSScriptRoot '../src/dotcheck/bin/Release/net10.0/dotcheck.exe'), [switch]$BaselineOnly)
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('dotcheck-tests-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $root)
$checks = 0
$oldPath = $env:PATH
$oldCase = $env:DOTCHECK_TEST_CASE
$oldPidFile = $env:DOTCHECK_TEST_PIDFILE
$realDotnet = (Get-Command dotnet -CommandType Application | Select-Object -First 1).Source
function Assert-Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }; $script:checks++
}
function Invoke-Tool([string[]]$Arguments) {
    $p = [Diagnostics.Process]::new()
    $p.StartInfo = [Diagnostics.ProcessStartInfo]::new($Tool)
    $p.StartInfo.WorkingDirectory = $root
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.CreateNoWindow = $true
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError = $true
    foreach ($a in $Arguments) { $p.StartInfo.ArgumentList.Add($a) }
    [void]$p.Start()
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(30000)) { $p.Kill($true); throw 'Harness timeout' }
    $r = @{ Exit = $p.ExitCode; Text = $out.GetAwaiter().GetResult(); Error = $err.GetAwaiter().GetResult() }
    $p.Dispose(); return $r
}
function Write-Trx([string]$Name, [string]$TestOutcome='Passed', [string]$RunOutcome='Completed', [bool]$RunError=$false) {
    $passed = [int]($TestOutcome -eq 'Passed'); $failed = [int]($TestOutcome -eq 'Failed'); $skip = [int]($TestOutcome -eq 'NotExecuted')
    $extra = if ($RunError) { '<RunInfos><RunInfo outcome="Error"><Text>Host unavailable; password=synthetic-do-not-display</Text></RunInfo></RunInfos>' } else { '' }
    $time = [datetime]::UtcNow.ToString('o')
    $path = Join-Path $root $Name
    [IO.File]::WriteAllText($path, "<TestRun><Times start='$time' finish='$time'/><Results><UnitTestResult testName='Synthetic.Test' outcome='$TestOutcome' duration='00:00:00.010'/></Results><ResultSummary outcome='$RunOutcome'><Counters total='1' passed='$passed' failed='$failed' notExecuted='$skip'/>$extra</ResultSummary></TestRun>")
    return $path
}
try {
    $passed = Write-Trx 'passed.trx'
    $failed = Write-Trx 'failed.trx' 'Failed' 'Failed'
    $skipped = Write-Trx 'skipped.trx' 'NotExecuted'
    $hostFailure = Write-Trx 'host.trx' 'Passed' 'Failed' $true
    foreach ($case in @(@($passed,0),@($failed,1),@($skipped,0),@($hostFailure,1))) {
        $r=Invoke-Tool @('-Path',$case[0],'-Json'); Assert-Check ($r.Exit -eq $case[1]) "reader $([IO.Path]::GetFileName($case[0]))"
    }
    $r=Invoke-Tool @('-Path',$skipped,'-FailOnSkipped','-Json'); Assert-Check ($r.Exit -eq 1) 'mandatory skips'
    $r=Invoke-Tool @('-Path',$hostFailure,'-Mode','RunErrors','-Json'); Assert-Check ($r.Text -notmatch 'synthetic-do-not-display' -and $r.Exit -eq 1) 'safe host diagnostics'
    foreach ($case in @('missing.trx','empty.trx','corrupt.trx')) {
        if ($case -ne 'missing.trx') { [IO.File]::WriteAllText((Join-Path $root $case), $(if ($case -eq 'empty.trx') {''} else {'<bad>'})) }
        $r=Invoke-Tool @('-Path',(Join-Path $root $case),'-Json'); Assert-Check ($r.Exit -eq 2) "invalid $case"
    }
    $r=Invoke-Tool @('-Path',$passed,'-NotBefore',[datetime]::UtcNow.AddDays(1).ToString('o'),'-Json'); Assert-Check ($r.Exit -eq 2) 'stale report'
    if ($BaselineOnly) { "PASS baselineChecks=$checks evidence=$root"; return }
    $journal=Join-Path $root 'journal.jsonl'; $id=[guid]::NewGuid().ToString('D'); $start=[datetime]::UtcNow.AddMinutes(-1).ToString('o')
    $entries=@(@{schemaVersion=1;event='started';runId=$id;startedUtc=$start;verb='test'},@{schemaVersion=1;event='finished';runId=$id;startedUtc=$start;result=@{exit=0;status='pass';outcome='passed';reports=@($passed)}})
    $entries | ForEach-Object {$_ | ConvertTo-Json -Depth 6 -Compress} | Set-Content $journal
    $r=Invoke-Tool @('-LastRun','-JournalPath',$journal,'-Json'); $v=$r.Text|ConvertFrom-Json; Assert-Check ($r.Exit -eq 0 -and $v.reportVerification -eq 'checked' -and $v.runId -eq $id) 'new journal replay'
    $r=Invoke-Tool @('-RunId',$id,'-JournalPath',$journal,'-Mode','Detail','-Test','Synthetic.Test','-Json'); Assert-Check ($r.Exit -eq 0) 'run selection detail'
    $id2=[guid]::NewGuid().ToString('D'); @{schemaVersion=1;event='started';runId=$id2;startedUtc=[datetime]::UtcNow.ToString('o');verb='test'} | ConvertTo-Json -Compress | Add-Content $journal
    $r=Invoke-Tool @('-LastRun','-JournalPath',$journal,'-Json'); $v=$r.Text|ConvertFrom-Json; Assert-Check ($r.Exit -eq 1 -and $v.outcome -eq 'unfinished') 'last started is not last successful'
    $r=Invoke-Tool @('-RunId',$id,'-JournalPath',$journal,'-Json'); Assert-Check ($r.Exit -eq 0) 'older explicit run'
    Remove-Item -LiteralPath $passed
    $r=Invoke-Tool @('-RunId',$id,'-JournalPath',$journal,'-Json'); Assert-Check ($r.Exit -ne 0) 'missing evidence cannot pass'
    $legacy=Join-Path $root 'legacy.jsonl'
    @(@{event='started';startedUtc=$start},@{event='finished';startedUtc=$start;verb='build';result=@{exit=0;status='pass';outcome='passed';phase='BUILD'}}) | ForEach-Object {$_|ConvertTo-Json -Compress} | Set-Content $legacy
    $r=Invoke-Tool @('-LastRun','-JournalPath',$legacy,'-Json'); $v=$r.Text|ConvertFrom-Json; Assert-Check ($r.Exit -eq 0 -and $v.reportVerification -eq 'not_applicable') 'legacy build journal'
    $r=Invoke-Tool @('-RunId',$start,'-JournalPath',$legacy,'-Json'); Assert-Check ($r.Exit -eq 0) 'legacy timestamp selection'
    Add-Content $legacy '{broken'; $r=Invoke-Tool @('-LastRun','-JournalPath',$legacy,'-Json'); Assert-Check ($r.Exit -eq 2) 'malformed journal'
    $invalidJournal=Join-Path $root 'invalid.jsonl'
    @{schemaVersion=99;event='started';runId=[guid]::NewGuid().ToString('D');startedUtc=$start} | ConvertTo-Json -Compress | Set-Content $invalidJournal
    $r=Invoke-Tool @('-LastRun','-JournalPath',$invalidJournal,'-Json'); Assert-Check ($r.Exit -eq 2) 'unknown journal schema'
    $entries[0] | ConvertTo-Json -Compress | Set-Content $invalidJournal
    $entries[0] | ConvertTo-Json -Compress | Add-Content $invalidJournal
    $r=Invoke-Tool @('-LastRun','-JournalPath',$invalidJournal,'-Json'); Assert-Check ($r.Exit -eq 2) 'duplicate run id'
    $r=Invoke-Tool @('-LastRun','-RunId',$id,'-JournalPath',$journal,'-Json'); Assert-Check ($r.Exit -eq 2) 'conflicting actions'
    $largeJournal=Join-Path $root 'large-line.jsonl';$largeId=[guid]::NewGuid().ToString('D')
    @(@{event='started';runId=$largeId;startedUtc=$start;verb='build'},@{event='finished';runId=$largeId;startedUtc=$start;result=@{exit=0;status='pass';outcome='passed';diagnostics=@(('x'*1100000))}}) |
        ForEach-Object{$_|ConvertTo-Json -Depth 6 -Compress}|Set-Content $largeJournal
    $r=Invoke-Tool @('-LastRun','-JournalPath',$largeJournal,'-Json');Assert-Check ($r.Exit -eq 0) 'valid large record within journal size limit'
    $r=Invoke-Tool @('-LastRun','-JournalPath',$largeJournal,'-MaxLogMiB','1','-Json');Assert-Check ($r.Exit -eq 2) 'journal size remains bounded'

    # Build a tiny owned native dotnet simulator, then exercise the actual runner/Job Object.
    # This deliberately avoids real application tests, SQL, external packages and fragile host crashes.
    $sdk = (& $realDotnet --version).Trim(); $tfm='net'+$sdk.Split('.')[0]+'.0'
    [IO.File]::WriteAllText((Join-Path $root 'sim.csproj'), "<Project Sdk='Microsoft.NET.Sdk'><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>$tfm</TargetFramework><AssemblyName>dotnet</AssemblyName><UseAppHost>true</UseAppHost></PropertyGroup></Project>")
    [IO.File]::WriteAllText((Join-Path $root 'Program.cs'), @'
using System;
using System.IO;
using System.Diagnostics;
using System.Threading;
class Program {
 static int Main(string[] args) {
  if (Array.IndexOf(args,"--child")>=0) {Thread.Sleep(120000);return 0;}
  var mode=Environment.GetEnvironmentVariable("DOTCHECK_TEST_CASE");
  if(mode=="hang" || mode=="orphan") {
   var child=Process.Start(new ProcessStartInfo(Environment.ProcessPath!,"--child"){UseShellExecute=false,CreateNoWindow=true});
   File.WriteAllText(Environment.GetEnvironmentVariable("DOTCHECK_TEST_PIDFILE")!,child!.Id.ToString());
   if(mode=="hang")Thread.Sleep(120000);return 0;
  }
  if(mode=="buildfail"){Console.Error.WriteLine("Program.cs(1,1): error CS1002: synthetic compiler failure");return 1;}
  if(mode=="build") {Thread.Sleep(1500);return 0;}
  var now=DateTime.UtcNow.ToString("o");
  var fail=mode=="assert"; var host=mode=="host"; var aborted=mode=="abort";
  var directory=Path.Combine(Environment.CurrentDirectory,"TestResults");Directory.CreateDirectory(directory);
  var path=Path.Combine(directory,Guid.NewGuid()+".trx");
  var extra=host?"<RunInfos><RunInfo outcome='Error'><Text>synthetic host failure</Text></RunInfo></RunInfos>":"";
  File.WriteAllText(path,$"<TestRun><Times start='{now}' finish='{now}'/><Results><UnitTestResult testName='Synthetic.Runner' outcome='{(fail?"Failed":"Passed")}' duration='00:00:00.010'/></Results><ResultSummary outcome='{(aborted?"Aborted":fail||host?"Failed":"Completed")}'><Counters total='1' passed='{(fail?0:1)}' failed='{(fail?1:0)}' notExecuted='0'/>{extra}</ResultSummary></TestRun>");
  Console.WriteLine("Results File: "+path);return fail||host||aborted?1:0;
 }
}
'@)
    $buildLog=Join-Path $root 'sim-build.log'
    & $realDotnet build (Join-Path $root 'sim.csproj') -o (Join-Path $root 'bin') -v:q -m:1 /nodeReuse:false *> $buildLog
    if ($LASTEXITCODE) { throw "Simulator build failed; evidence: $buildLog" }
    $env:PATH=(Join-Path $root 'bin')+[IO.Path]::PathSeparator+$oldPath
    $env:DOTCHECK_TEST_PIDFILE=Join-Path $root 'child.pid'
    Push-Location $root
    try {
        foreach ($case in @(@('pass','passed',0),@('assert','tests_failed',1),@('host','test_run_failed',1),@('abort','aborted',1),@('buildfail','build_failed',1))) {
            $env:DOTCHECK_TEST_CASE=$case[0]
            $r=Invoke-Tool @('-Run','-Project',(Join-Path $root 'sim.csproj'),'-Json','-JournalPath',(Join-Path $root 'runner.jsonl'),'-Reason','synthetic runner regression')
            $v=$r.Text|ConvertFrom-Json
            Assert-Check ($r.Exit -eq $case[2] -and $v.outcome -eq $case[1] -and $v.processTreeCompleted) "runner $($case[0])"
        }
        $records=Get-Content (Join-Path $root 'runner.jsonl') | ForEach-Object {$_|ConvertFrom-Json}
        $starts=@($records|Where-Object event -eq started); $finishes=@($records|Where-Object event -eq finished)
        Assert-Check ($starts.Count -eq 5 -and $finishes.Count -eq 5 -and $starts[0].schemaVersion -eq 1 -and $starts[0].runId -eq $finishes[0].runId -and $finishes[0].finishedUtc) 'new runner journal fields'
        $r=Invoke-Tool @('-RunId',$finishes[0].runId,'-JournalPath',(Join-Path $root 'runner.jsonl'),'-Json'); Assert-Check ($r.Exit -eq 0) 'actual runner replay'
        $r=Invoke-Tool @('-RunId',$finishes[2].runId,'-JournalPath',(Join-Path $root 'runner.jsonl'),'-Mode','RunErrors','-Json'); $v=$r.Text|ConvertFrom-Json
        Assert-Check ($r.Exit -eq 1 -and $v.inspection.items.Count -gt 0) 'run errors through journal'
        $r=Invoke-Tool @('-RunId',$finishes[4].runId,'-JournalPath',(Join-Path $root 'runner.jsonl'),'-Json'); $v=$r.Text|ConvertFrom-Json
        Assert-Check ($r.Exit -eq 1 -and $v.recordedDiagnostics[0].code -eq 'CS1002') 'saved compiler failure summary'
        $r=Invoke-Tool @('-RunId',$finishes[4].runId,'-JournalPath',(Join-Path $root 'runner.jsonl'),'-Mode','Errors','-Json'); $v=$r.Text|ConvertFrom-Json
        Assert-Check ($r.Exit -eq 1 -and $v.diagnosticsAvailable -and $v.recordedDiagnostics[0].level -eq 'error') 'saved compiler errors mode'
        $r=Invoke-Tool @('-RunId',$finishes[0].runId,'-JournalPath',(Join-Path $root 'runner.jsonl'),'-Mode','Warnings','-Json'); $v=$r.Text|ConvertFrom-Json
        Assert-Check ($r.Exit -eq 0 -and -not $v.diagnosticsAvailable) 'missing warnings are not zero warnings'
        $env:DOTCHECK_TEST_CASE='build'
        $r=Invoke-Tool @('-Build','-Project',(Join-Path $root 'sim.csproj'),'-HeartbeatSeconds','1','-Json')
        $v=$r.Text|ConvertFrom-Json; Assert-Check ($r.Exit -eq 0 -and $r.Error -match 'RUNNING elapsed=' -and $v.outcome -eq 'passed') 'heartbeat separate stderr'
        foreach ($mode in @('hang','orphan')) {
            $env:DOTCHECK_TEST_CASE=$mode
            $r=Invoke-Tool @('-Build','-Project',(Join-Path $root 'sim.csproj'),'-TimeoutSeconds','1','-Json')
            $v=$r.Text|ConvertFrom-Json; $childId=[int](Get-Content $env:DOTCHECK_TEST_PIDFILE)
            Assert-Check ($v.processTreeCompleted -and -not (Get-Process -Id $childId -ErrorAction SilentlyContinue)) "owned child cleanup $mode"
            if ($mode -eq 'hang') { Assert-Check ($r.Exit -eq 124 -and $v.outcome -eq 'timeout') 'timeout exit' }
        }
        $abruptJournal=Join-Path $root 'abrupt.jsonl';$env:DOTCHECK_TEST_CASE='hang'
        $env:DOTCHECK_TEST_PIDFILE=Join-Path $root 'abrupt-child.pid'
        $parent=[Diagnostics.Process]::new();$parent.StartInfo=[Diagnostics.ProcessStartInfo]::new($Tool)
        $parent.StartInfo.WorkingDirectory=$root
        $parent.StartInfo.UseShellExecute=$false;$parent.StartInfo.CreateNoWindow=$true
        $parent.StartInfo.RedirectStandardOutput=$true;$parent.StartInfo.RedirectStandardError=$true
        foreach($a in @('-Build','-Project',(Join-Path $root 'sim.csproj'),'-JournalPath',$abruptJournal,'-Reason','abrupt parent regression','-Json')){$parent.StartInfo.ArgumentList.Add($a)}
        $ownedChild=$null
        try {
            [void]$parent.Start();$parentOut=$parent.StandardOutput.ReadToEndAsync();$parentErr=$parent.StandardError.ReadToEndAsync()
            $wait=[Diagnostics.Stopwatch]::StartNew()
            while(-not(Test-Path $env:DOTCHECK_TEST_PIDFILE) -and $wait.Elapsed.TotalSeconds -lt 10){Start-Sleep -Milliseconds 25}
            if(-not(Test-Path $env:DOTCHECK_TEST_PIDFILE)){throw 'Abrupt child did not start'}
            $ownedChild=[Diagnostics.Process]::GetProcessById([int](Get-Content $env:DOTCHECK_TEST_PIDFILE))
            if($ownedChild.MainModule.FileName -ne (Join-Path $root 'bin/dotnet.exe')){throw 'Unexpected child target'}
            $parent.Kill();[void]$parent.WaitForExit(5000) # Kill only the runner, so its Job Object must clean descendants.
            $wait.Restart();while(-not $ownedChild.HasExited -and $wait.Elapsed.TotalSeconds -lt 5){Start-Sleep -Milliseconds 25}
            Assert-Check $ownedChild.HasExited 'Job Object cleans children after abrupt runner kill'
            $r=Invoke-Tool @('-LastRun','-JournalPath',$abruptJournal,'-Json');$v=$r.Text|ConvertFrom-Json
            Assert-Check ($r.Exit -eq 1 -and $v.outcome -eq 'unfinished') 'abrupt runner leaves unconfirmed start'
        } finally {
            if(-not $parent.HasExited){$parent.Kill($true);[void]$parent.WaitForExit(5000)};$parent.Dispose()
            if($null -ne $ownedChild){if(-not $ownedChild.HasExited){$ownedChild.Kill();[void]$ownedChild.WaitForExit(5000)};$ownedChild.Dispose()}
        }
        $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant())))
        $mutex=[Threading.Mutex]::new($false,"dotcheck-$key");[void]$mutex.WaitOne()
        try {
            $r=Invoke-Tool @('-Build','-Project',(Join-Path $root 'sim.csproj'),'-Json','-JournalPath',(Join-Path $root 'runner.jsonl'),'-Reason','refused run regression')
            $v=$r.Text|ConvertFrom-Json; Assert-Check ($r.Exit -ne 0 -and $v.condition -eq 'build_outputs_busy') 'competing runner refuses'
        }
        finally {$mutex.ReleaseMutex();$mutex.Dispose()}
        $r=Invoke-Tool @('-LastRun','-JournalPath',(Join-Path $root 'runner.jsonl'),'-Json'); $v=$r.Text|ConvertFrom-Json
        Assert-Check ($r.Exit -eq 2 -and $v.outcome -eq 'runner_failed' -and $v.reportVerification -eq 'not_applicable') 'mutex refusal preserves readable journal'
        $r=Invoke-Tool @('-RunId',$finishes[0].runId,'-JournalPath',(Join-Path $root 'runner.jsonl'),'-Json'); Assert-Check ($r.Exit -eq 0) 'previous success readable after refusal'
        $legacyRefusal=Join-Path $root 'legacy-refusal.jsonl'
        @{schemaVersion=1;toolVersion='1.1.0';event='finished';runId=[guid]::NewGuid().ToString('D');startedUtc=$start;verb='build';result=@{exit=2;status='fail';outcome='runner_failed';condition='build_outputs_busy';processTreeCompleted=$null}} | ConvertTo-Json -Depth 6 -Compress | Set-Content $legacyRefusal
        $r=Invoke-Tool @('-LastRun','-JournalPath',$legacyRefusal,'-Json'); $v=$r.Text|ConvertFrom-Json
        Assert-Check ($r.Exit -eq 2 -and $v.startEventMissing) 'known legacy refusal stays failed and readable'
        $badFinish=Get-Content $legacyRefusal -Raw|ConvertFrom-Json; $badFinish.toolVersion='1.1.1';$badFinish|ConvertTo-Json -Depth 6 -Compress|Set-Content $legacyRefusal
        $r=Invoke-Tool @('-LastRun','-JournalPath',$legacyRefusal,'-Json'); $v=$r.Text|ConvertFrom-Json
        Assert-Check ($r.Exit -eq 2 -and $v.error -eq 'invalid_journal') 'new unmatched finish rejected'
        $env:DOTCHECK_TEST_CASE='build'
        $earlyJournal=Join-Path $root 'early.jsonl'; $existingLog=Join-Path $root 'existing.log'; Set-Content $existingLog 'retain'
        $r=Invoke-Tool @('-Build','-Project',(Join-Path $root 'sim.csproj'),'-LogPath',$existingLog,'-JournalPath',$earlyJournal,'-Reason','existing log refusal','-Json')
        Assert-Check ($r.Exit -ne 0 -and (Get-Content $existingLog -Raw).Trim() -eq 'retain') 'existing log is preserved'
        $r=Invoke-Tool @('-LastRun','-JournalPath',$earlyJournal,'-Json'); $v=$r.Text|ConvertFrom-Json
        Assert-Check ($r.Exit -ne 0 -and $v.outcome -eq 'runner_failed') 'early log refusal has readable pair'
        $missingParent=Join-Path $root 'absent/journal.jsonl'
        $r=Invoke-Tool @('-Build','-Project',(Join-Path $root 'sim.csproj'),'-JournalPath',$missingParent,'-Reason','missing parent regression','-Json');$v=$r.Text|ConvertFrom-Json
        Assert-Check ($r.Exit -ne 0 -and $v.condition -eq 'journal_parent_missing' -and -not(Test-Path $missingParent)) 'unwritable journal creates no orphan finish'
        foreach ($case in @(@('total',-1),@('seconds','NaN'),@('processTreeCompleted','false'))) {
            $badJournal=Join-Path $root 'bad-metadata.jsonl';$badId=[guid]::NewGuid().ToString('D')
            $result=@{exit=0;status='pass';outcome='passed';phase='BUILD'};$result[$case[0]]=$case[1]
            @(@{event='started';runId=$badId;startedUtc=$start;verb='build'},@{event='finished';runId=$badId;startedUtc=$start;result=$result}) |
                ForEach-Object {$_|ConvertTo-Json -Depth 6 -Compress}|Set-Content $badJournal
            $r=Invoke-Tool @('-LastRun','-JournalPath',$badJournal,'-Json');$v=$r.Text|ConvertFrom-Json
            Assert-Check ($r.Exit -eq 2 -and $v.error -eq 'invalid_journal') "malformed metadata $($case[0])"
        }
        $oldDiagnostics=Join-Path $root 'old-diagnostics.jsonl';$oldId=[guid]::NewGuid().ToString('D')
        $oldResult=@{exit=1;status='fail';outcome='build_failed';errorDiagnostics=1;warningDiagnostics=1;items=@(@{code='CS1002';message='password=old-synthetic-secret'})}
        $oldEntries=@(@{event='started';runId=$oldId;startedUtc=$start;verb='build'},@{event='finished';runId=$oldId;startedUtc=$start;result=$oldResult})
        $oldEntries|ForEach-Object{$_|ConvertTo-Json -Depth 6 -Compress}|Set-Content $oldDiagnostics
        $r=Invoke-Tool @('-LastRun','-JournalPath',$oldDiagnostics,'-Mode','Errors','-Json');$v=$r.Text|ConvertFrom-Json
        Assert-Check ($r.Exit -eq 1 -and -not $v.diagnosticsAvailable) 'ambiguous legacy severity is not guessed'
        $r=Invoke-Tool @('-LastRun','-JournalPath',$oldDiagnostics,'-Json');$v=$r.Text|ConvertFrom-Json
        Assert-Check ($v.recordedDiagnostics[0].level -eq 'unknown' -and $r.Text -notmatch 'old-synthetic-secret') 'legacy summary retains sanitized unknown diagnostic'
        $oldResult.warningDiagnostics=0;$oldEntries|ForEach-Object{$_|ConvertTo-Json -Depth 6 -Compress}|Set-Content $oldDiagnostics
        $r=Invoke-Tool @('-LastRun','-JournalPath',$oldDiagnostics,'-Mode','Errors','-Json');$v=$r.Text|ConvertFrom-Json
        Assert-Check ($r.Exit -eq 1 -and $v.recordedDiagnostics[0].level -eq 'error') 'unambiguous legacy compiler severity'
        $sharedJournal=Join-Path $root 'shared.jsonl'
        $workers=[Collections.Generic.List[object]]::new()
        try {
            foreach ($n in 1..2) {
                $p=[Diagnostics.Process]::new();$p.StartInfo=[Diagnostics.ProcessStartInfo]::new($Tool)
                $p.StartInfo.WorkingDirectory=$root
                $p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true
                $p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
                foreach($a in @('-Build','-Project',(Join-Path $root 'sim.csproj'),'-LockRoot',(Join-Path $root "lock$n"),'-JournalPath',$sharedJournal,'-Reason','shared journal writer','-Json')){$p.StartInfo.ArgumentList.Add($a)}
                [void]$p.Start();$workers.Add(@{Process=$p;Out=$p.StandardOutput.ReadToEndAsync();Err=$p.StandardError.ReadToEndAsync()})
            }
            $wait=[Diagnostics.Stopwatch]::StartNew()
            while(-not(Test-Path $sharedJournal) -and $wait.Elapsed.TotalSeconds -lt 10){Start-Sleep -Milliseconds 25}
            $r=Invoke-Tool @('-LastRun','-JournalPath',$sharedJournal,'-Json')
            Assert-Check ($r.Exit -in @(0,1)) 'inspect active shared journal without corrupt snapshot'
            foreach($worker in $workers){
                if(-not $worker.Process.WaitForExit(30000)){throw 'Shared journal worker timeout'}
                $v=$worker.Out.GetAwaiter().GetResult()|ConvertFrom-Json
                Assert-Check ($worker.Process.ExitCode -eq 0 -and $v.outcome -eq 'passed') 'shared writer survives inspection'
            }
            $r=Invoke-Tool @('-LastRun','-JournalPath',$sharedJournal,'-Json');Assert-Check ($r.Exit -eq 0) 'completed shared journal readable'
            $records=@(Get-Content $sharedJournal|ForEach-Object{$_|ConvertFrom-Json})
            Assert-Check ($records.Count -eq 4 -and @($records|Where-Object event -eq started).Count -eq 2) 'shared journal contains complete pairs'
        } finally {
            foreach($worker in $workers){if(-not $worker.Process.HasExited){$worker.Process.Kill($true);[void]$worker.Process.WaitForExit(5000)};$worker.Process.Dispose()}
        }
    } finally {Pop-Location}
    "PASS checks=$checks evidence=$root"
} finally {
    $env:PATH=$oldPath;$env:DOTCHECK_TEST_CASE=$oldCase;$env:DOTCHECK_TEST_PIDFILE=$oldPidFile
    # Evidence retained intentionally; no deletion of shared resources or unrelated processes.
}
