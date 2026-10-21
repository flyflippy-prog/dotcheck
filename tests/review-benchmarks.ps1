#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReferenceTool,
    [Parameter(Mandatory)][string]$CandidateTool,
    [ValidateRange(3, 31)][int]$Repetitions = 7,
    [string]$OutputFile = (Join-Path $PSScriptRoot '../evidence/code-review-benchmarks.json')
)
$ErrorActionPreference = 'Stop'
$ReferenceTool = (Resolve-Path -LiteralPath $ReferenceTool).Path
$CandidateTool = (Resolve-Path -LiteralPath $CandidateTool).Path
if (Test-Path -LiteralPath $OutputFile) { throw 'Choose a new output file; measurements are preserved' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('dotcheck-review-benchmark-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $root)
$large = Join-Path $root 'large.trx'
$builder = [Text.StringBuilder]::new('<TestRun><Results>')
foreach ($i in 1..10000) {
    [void]$builder.Append("<UnitTestResult testName='Synthetic.Test$i' outcome='Passed' duration='00:00:00.001'/>")
}
[void]$builder.Append("</Results><ResultSummary outcome='Completed'><Counters total='10000' passed='10000' failed='0' notExecuted='0'/></ResultSummary></TestRun>")
[IO.File]::WriteAllText($large, $builder.ToString())
$journal = Join-Path $root 'journal.jsonl'
[void]$builder.Clear()
foreach ($i in 1..1000) {
    $id = [guid]::NewGuid().ToString('D')
    [void]$builder.AppendLine((@{ event='started'; runId=$id; startedUtc='2026-10-20T00:00:00Z'; verb='build' } | ConvertTo-Json -Compress))
    [void]$builder.AppendLine((@{ event='finished'; runId=$id; startedUtc='2026-10-20T00:00:00Z'; result=@{ exit=0; status='pass'; outcome='passed' } } | ConvertTo-Json -Depth 4 -Compress))
}
[IO.File]::WriteAllText($journal, $builder.ToString())

function Sample([string]$Tool, [string[]]$Arguments) {
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = [Diagnostics.ProcessStartInfo]::new($Tool)
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.WorkingDirectory = $root
    foreach ($argument in $Arguments) { $process.StartInfo.ArgumentList.Add($argument) }
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $peak = 0L
        while (-not $process.WaitForExit(2)) {
            try { $process.Refresh(); $peak = [math]::Max($peak, $process.PeakWorkingSet64) } catch { }
            if ($timer.ElapsedMilliseconds -gt 15000) { $process.Kill($true); throw 'Benchmark timeout' }
        }
        $timer.Stop()
        $text = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $peak -eq 0) { throw 'Workload failed or no live memory sample was obtained' }
        $null = $text | ConvertFrom-Json
        return @{ milliseconds=$timer.Elapsed.TotalMilliseconds; peakRootBytes=$peak }
    } finally { $process.Dispose() }
}

$results = [Collections.Generic.List[object]]::new()
foreach ($workload in @(
    @{ name='startup'; arguments=@('-Help','-Json') },
    @{ name='reader10000'; arguments=@('-Path',$large,'-Json') },
    @{ name='journal1000'; arguments=@('-LastRun','-JournalPath',$journal,'-Json') }
)) {
    $samples = @{ reference=[Collections.Generic.List[object]]::new(); candidate=[Collections.Generic.List[object]]::new() }
    $null = Sample $ReferenceTool $workload.arguments
    $null = Sample $CandidateTool $workload.arguments
    foreach ($i in 1..$Repetitions) {
        # Alternate order to reduce systematic ordering bias.
        $order = if ($i % 2) { @('reference','candidate') } else { @('candidate','reference') }
        foreach ($variant in $order) {
            $tool = if ($variant -eq 'reference') { $ReferenceTool } else { $CandidateTool }
            $samples[$variant].Add((Sample $tool $workload.arguments))
        }
    }
    foreach ($variant in @('reference','candidate')) {
        $times = @($samples[$variant].milliseconds | Sort-Object)
        $memory = @($samples[$variant].peakRootBytes | Sort-Object)
        $results.Add(@{ workload=$workload.name; variant=$variant; samples=$samples[$variant].ToArray(); medianMs=$times[[int][math]::Floor($Repetitions/2)]; p95Ms=$times[[int][math]::Ceiling(.95*$Repetitions)-1]; medianPeakRootBytes=$memory[[int][math]::Floor($Repetitions/2)] })
    }
}
$payload = @{
    utc=[datetime]::UtcNow.ToString('o'); repetitions=$Repetitions; fixtureRoot=$root
    method='One warm-up per variant/workload; alternating measured launches; warm OS caches; root PeakWorkingSet64 sampled alive about every 2 ms; no compilation or true cold-cache claim'
    reference=@{ sha256=(Get-FileHash $ReferenceTool).Hash; bytes=(Get-Item $ReferenceTool).Length }
    candidate=@{ sha256=(Get-FileHash $CandidateTool).Hash; bytes=(Get-Item $CandidateTool).Length }
    largeTrxBytes=(Get-Item $large).Length; journalBytes=(Get-Item $journal).Length; results=$results.ToArray()
}
$outputPath = [IO.Path]::GetFullPath($OutputFile)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputPath))
$stream = [IO.FileStream]::new($outputPath, [IO.FileMode]::CreateNew)
try {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 10))
    $stream.Write($bytes)
} finally { $stream.Dispose() }
"PASS benchmark results=$OutputFile fixtures=$root"
