#requires -Version 5.1
# dotcheck-tool-id: 48683d33-42bd-4ff8-808f-6a12c8795c89
<#
.SYNOPSIS
Run dotnet build/test or read TRX; emit bounded, mode-specific output.
.DESCRIPTION
Modes: Summary, Failed, Skipped, Slow, Detail, RunErrors.
Exit: 0 healthy report, 1 test/run failure (or -FailOnSkipped), 2 input/report error.
See dotcheck.README.md beside this script for examples and limits.
#>
[CmdletBinding()]
param(
    [Alias('p')][string[]]$Path = @(),
    [string]$Mode = 'Summary',
    [string]$Test = '',
    [int]$Top = 5,
    [int]$MaxChars = 350,
    [int]$StackLines = 0,
    [switch]$Json,
    [switch]$Recurse,
    [switch]$FailOnSkipped,
    [Alias('h', '?')][switch]$Help,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Build,
    [switch]$Run,
    [switch]$Clean,
    [string]$Project = '.',
    [string]$Configuration = 'Debug',
    [string]$Framework = '',
    [string]$Filter = '',
    [string]$Runner = 'Auto',
    [switch]$NoRestore,
    [switch]$NoBuild,
    [string[]]$DotnetArgs = @(),
    [int]$TimeoutSeconds = 600,
    [string]$ResultsDirectory = '',
    [string]$LogPath = '',
    [string]$JournalPath = '',
    [switch]$LastRun,
    [string]$RunId = '',
    [int]$HeartbeatSeconds = 0,
    [string]$Reason = '',
    [string]$LockRoot = '',
    [ValidateRange(-1,2147483647)][int]$MaxWarningDiagnostics = -1,
    [int]$KeepReports = 10,
    [int]$MaxLogMiB = 64,
    [Nullable[datetime]]$NotBefore,
    [int]$MaxFiles = 100,
    [int]$MaxFileMiB = 128
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:toolVersion = '1.1.2'
$script:rows = [System.Collections.Generic.List[object]]::new()
$script:matched = 0
$script:unranked = 0
$script:inputErrorCount = 0
$script:inputErrors = [System.Collections.Generic.List[object]]::new()
$script:reports = [System.Collections.Generic.List[object]]::new()
$script:includeFailureMessages = $false
$script:argumentDiagnostic = $null

function Stop-InvalidArguments {
    param([string]$Message)
    $script:argumentDiagnostic = [ordered]@{ message = $Message }
    throw 'invalid_arguments'
}

function Assert-ArgumentRange {
    param([string]$Name, [int]$Value, [int]$Minimum, [int]$Maximum)
    if ($Value -lt $Minimum -or $Value -gt $Maximum) {
        $script:argumentDiagnostic = [ordered]@{
            message = "$Name=$Value must be between $Minimum and $Maximum (inclusive)."
            argument = $Name; value = $Value; minimum = $Minimum; maximum = $Maximum
        }
        throw 'invalid_arguments'
    }
}

function Safe-Text {
    param([AllowNull()][string]$Value, [int]$Limit = $MaxChars)
    if ($null -eq $Value) { $Value = '' }
    $text = [regex]::Replace($Value, '(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+', '$1 [redacted]')
    $text = [regex]::Replace($text, '\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b', '[redacted]')
    $text = [regex]::Replace($text, '(?i)\b(password|pwd|secret|token|api[-_]?key|access[-_]?key|authorization|connection[-_]?string)["'']?\s*[:=]\s*(?:"[^"]*"|''[^'']*''|[^\s,;]+)', '$1=[redacted]')
    $text = [regex]::Replace($text, '(?i)(https?://)[^\s/@]+:[^\s/@]+@', '$1[redacted]@')
    $text = [regex]::Replace($text, '(?i)(https?://[^\s?#]+)\?[^\s#]+', '$1?[redacted]')
    $text = [regex]::Replace($text, '[\p{Cc}\p{Cf}\s]+', ' ').Trim()
    $cut = $text.Length -gt $Limit
    if ($cut) { $text = $text.Substring(0, $Limit - 3) + '...' }
    [pscustomobject]@{ Text = $text; Truncated = $cut }
}

function Add-InputError {
    param([string]$Report, [string]$Code)
    $script:inputErrorCount++
    if ($script:inputErrors.Count -lt $Top) {
        $script:inputErrors.Add([pscustomobject]@{ report = (Safe-Text $Report).Text; error = $Code })
    }
}

function Add-Row {
    param([object]$Row)
    $script:matched++
    if ($Mode -eq 'Slow') {
        if ($script:rows.Count -eq $Top -and $Row.seconds -le $script:rows[$Top - 1].seconds) { return }
        $index = 0
        while ($index -lt $script:rows.Count -and $script:rows[$index].seconds -ge $Row.seconds) { $index++ }
        $script:rows.Insert($index, $Row)
        if ($script:rows.Count -gt $Top) { $script:rows.RemoveAt($Top) }
    } elseif ($script:rows.Count -lt $Top) {
        $script:rows.Add($Row)
    }
}

function Limited-ElementText {
    param([System.Xml.XmlReader]$Reader)
    # Read only a bounded prefix; closing a subtree consumes its remainder without emitting it.
    $limit = [Math]::Max(8192, $MaxChars * 4)
    $sub = $Reader.ReadSubtree()
    $builder = [System.Text.StringBuilder]::new()
    $buffer = [char[]]::new(256)
    $cut = $false
    try {
        while ($sub.Read()) {
            if ($sub.NodeType -in @([System.Xml.XmlNodeType]::Text, [System.Xml.XmlNodeType]::CDATA,
                    [System.Xml.XmlNodeType]::Whitespace, [System.Xml.XmlNodeType]::SignificantWhitespace)) {
                while (($n = $sub.ReadValueChunk($buffer, 0, $buffer.Length)) -gt 0) {
                    $take = [Math]::Min($n, $limit - $builder.Length)
                    if ($take -gt 0) { [void]$builder.Append($buffer, 0, $take) }
                    if ($take -lt $n) { $cut = $true; break }
                }
            }
            if ($cut) { break }
        }
    } finally { $sub.Dispose() }
    [pscustomobject]@{ Text = $builder.ToString(); Truncated = $cut }
}

function Skip-Element {
    param([System.Xml.XmlReader]$Reader)
    $sub = $Reader.ReadSubtree()
    $sub.Dispose()
}

function Read-Details {
    param([System.Xml.XmlReader]$Reader, [switch]$IncludeDiagnostic)
    $detail = [ordered]@{}
    $sub = $Reader.ReadSubtree()
    try {
        while ($sub.Read()) {
            if ($sub.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            if ($sub.LocalName -eq 'InnerResults' -or ($sub.LocalName -eq 'UnitTestResult' -and $sub.Depth -gt 0)) {
                throw 'unsupported_hierarchy'
            } elseif ($sub.LocalName -in @('StdOut', 'StdErr', 'ResultFiles', 'CollectorDataEntries')) {
                Skip-Element $sub
            } elseif ($sub.LocalName -eq 'ErrorInfo' -and -not $IncludeDiagnostic) {
                Skip-Element $sub
            } elseif ($sub.LocalName -eq 'Message' -and $sub.Depth -eq 3 -and $IncludeDiagnostic) {
                $raw = Limited-ElementText $sub
                $safe = Safe-Text $raw.Text
                if ($safe.Text) { $detail.message = $safe.Text }
                if ($raw.Truncated -or $safe.Truncated) { $detail.truncated = $true }
            } elseif ($sub.LocalName -eq 'StackTrace' -and $sub.Depth -eq 3 -and $StackLines -gt 0 -and $IncludeDiagnostic) {
                $raw = Limited-ElementText $sub
                $lines = @($raw.Text -split '\r?\n' | Where-Object { $_.Trim() })
                $safe = Safe-Text (($lines | Select-Object -First $StackLines) -join ' | ')
                if ($safe.Text) { $detail.stack = $safe.Text }
                if ($raw.Truncated -or $safe.Truncated -or $lines.Count -gt $StackLines) { $detail.truncated = $true }
            } elseif ($sub.LocalName -eq 'StackTrace') {
                Skip-Element $sub
            }
        }
    } finally { $sub.Dispose() }
    $detail
}

function Read-Report {
    param([System.IO.FileInfo]$File)
    $data = [ordered]@{
        report = (Safe-Text $File.Name).Text
        total = 0L; passed = 0L; failed = 0L; skipped = 0L; other = 0L
        runErrors = 0L; badRun = $false; invalid = $false; seconds = $null; runOutcome = ''
    }
    $actual = @{ total = 0L; passed = 0L; failed = 0L; skipped = 0L; other = 0L }
    $seenCounters = $false
    $seenSummary = $false
    $seenStart = $false
    $section = ''
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.IgnoreComments = $true
    $settings.IgnoreProcessingInstructions = $true
    $settings.MaxCharactersInDocument = [long]$MaxFileMiB * 1024 * 1024
    $reader = $null
    try {
        if ($File.Length -gt [long]$MaxFileMiB * 1024 * 1024) { throw 'file_too_large' }
        $reader = [System.Xml.XmlReader]::Create($File.FullName, $settings)
        [void]$reader.MoveToContent()
        if ($reader.LocalName -ne 'TestRun' -or $reader.Depth -ne 0) { throw 'not_trx' }
        while ($reader.Read()) {
            if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            if ($reader.Depth -eq 1) { $section = $reader.LocalName }
            if ($section -eq 'Times' -and $reader.Depth -eq 1) {
                $start = [datetimeoffset]::MinValue
                $finish = [datetimeoffset]::MinValue
                if ([datetimeoffset]::TryParse($reader.GetAttribute('start'), [ref]$start) -and
                    [datetimeoffset]::TryParse($reader.GetAttribute('finish'), [ref]$finish) -and $finish -ge $start) {
                    $seenStart = $true
                    if ($null -ne $NotBefore -and $start.UtcDateTime -lt ([datetime]$NotBefore).ToUniversalTime()) {
                        throw 'stale_run'
                    }
                    $data.seconds = [Math]::Round(($finish - $start).TotalSeconds, 3)
                }
            } elseif ($section -eq 'Results' -and $reader.LocalName -eq 'UnitTestResult' -and $reader.Depth -eq 2) {
                $name = $reader.GetAttribute('testName')
                $outcome = $reader.GetAttribute('outcome')
                $duration = [timespan]::Zero
                $hasDuration = [timespan]::TryParse($reader.GetAttribute('duration'), [ref]$duration)
                $actual.total++
                if ($outcome -eq 'Passed') { $actual.passed++ }
                elseif ($outcome -in @('Failed', 'Error', 'Timeout', 'Aborted')) { $actual.failed++ }
                elseif ($outcome -in @('NotExecuted', 'Skipped')) { $actual.skipped++ }
                else { $actual.other++ }
                $matches = (-not $Test) -or ($null -ne $name -and $name.IndexOf($Test, [StringComparison]::OrdinalIgnoreCase) -ge 0)
                if ($Mode -eq 'Slow' -and $matches -and (-not $hasDuration -or $duration -lt [timespan]::Zero)) {
                    $script:unranked++
                }
                $wanted = $matches -and (
                    ($Mode -eq 'Failed' -and $outcome -in @('Failed', 'Error', 'Timeout', 'Aborted')) -or
                    ($Mode -eq 'Skipped' -and $outcome -in @('NotExecuted', 'Skipped')) -or
                    ($Mode -eq 'Slow' -and $hasDuration -and $duration -ge [timespan]::Zero) -or
                    $Mode -eq 'Detail')
                if ($wanted) {
                    if ($Mode -eq 'Slow' -and $script:rows.Count -eq $Top -and
                        $duration.TotalSeconds -le $script:rows[$Top - 1].seconds) {
                        $script:matched++
                        [void](Read-Details $reader)
                        continue
                    }
                    if ($Mode -ne 'Slow' -and $script:rows.Count -ge $Top) {
                        $script:matched++
                        [void](Read-Details $reader)
                        continue
                    }
                    $safeName = Safe-Text $name
                    $row = [ordered]@{ report = $data.report; test = $safeName.Text }
                    if ($Mode -in @('Detail', 'Slow') -or $outcome -notin @('Failed', 'NotExecuted', 'Skipped')) {
                        $row.outcome = (Safe-Text $outcome).Text
                    }
                    if ($safeName.Truncated) { $row.truncated = $true }
                    if ($Mode -eq 'Slow') { $row.seconds = $duration.TotalSeconds }
                    if (($Mode -eq 'Detail' -or ($Mode -eq 'Failed' -and $script:includeFailureMessages)) -and $script:rows.Count -lt $Top) {
                        $details = Read-Details $reader -IncludeDiagnostic
                        foreach ($key in $details.Keys) { $row[$key] = $details[$key] }
                    } else { [void](Read-Details $reader) }
                    Add-Row ([pscustomobject]$row)
                } else { [void](Read-Details $reader) }
            } elseif ($section -eq 'ResultSummary' -and $reader.Depth -eq 1) {
                $data.runOutcome = $reader.GetAttribute('outcome')
                if ($seenSummary) { throw 'duplicate_summary' }
                $seenSummary = $true
                $runOutcome = $reader.GetAttribute('outcome')
                if ($runOutcome -notin @('Completed', 'Passed')) {
                    $data.badRun = $true
                    if ($Mode -eq 'RunErrors') {
                        Add-Row ([pscustomobject]@{ report = $data.report; level = 'outcome'; message = (Safe-Text $runOutcome).Text })
                    }
                }
            } elseif ($section -eq 'ResultSummary' -and $reader.LocalName -eq 'Counters' -and $reader.Depth -eq 2) {
                if ($seenCounters) { throw 'duplicate_counters' }
                $seenCounters = $true
                foreach ($key in @('total', 'passed', 'failed', 'notExecuted')) {
                    $value = 0L
                    if (-not [long]::TryParse($reader.GetAttribute($key), [ref]$value) -or $value -lt 0) {
                        throw 'invalid_counters'
                    }
                    $target = $key
                    if ($key -eq 'notExecuted') { $target = 'skipped' }
                    $data[$target] = $value
                }
                foreach ($key in @('error', 'timeout', 'aborted')) {
                    $attr = $reader.GetAttribute($key)
                    if ($null -ne $attr) {
                        $value = 0L
                        if (-not [long]::TryParse($attr, [ref]$value) -or $value -lt 0) { throw 'invalid_counters' }
                        $data.failed += $value
                    }
                }
                $data.other = $data.total - $data.passed - $data.failed - $data.skipped
                if ($data.other -lt 0) { throw 'invalid_counters' }
            } elseif ($section -eq 'ResultSummary' -and $reader.LocalName -eq 'RunInfo') {
                $level = $reader.GetAttribute('outcome')
                if ($level -in @('Error', 'Failed', 'Timeout', 'Aborted')) {
                    $data.runErrors++
                    $data.badRun = $true
                }
                if ($Mode -eq 'RunErrors') {
                    $raw = Limited-ElementText $reader
                    $safe = Safe-Text $raw.Text
                    Add-Row ([pscustomobject]@{ report = $data.report; level = (Safe-Text $level).Text; message = $safe.Text; truncated = ($raw.Truncated -or $safe.Truncated) })
                } else { Skip-Element $reader }
            } elseif ($section -eq 'ResultSummary' -and $reader.LocalName -eq 'ErrorInfo') {
                $data.runErrors++
                $data.badRun = $true
                if ($Mode -eq 'RunErrors') {
                    $sub = $reader.ReadSubtree()
                    try {
                        while ($sub.Read()) {
                            if ($sub.NodeType -eq [System.Xml.XmlNodeType]::Element -and $sub.LocalName -eq 'Message') {
                                $raw = Limited-ElementText $sub
                                $safe = Safe-Text $raw.Text
                                Add-Row ([pscustomobject]@{ report = $data.report; level = 'error'; message = $safe.Text; truncated = ($raw.Truncated -or $safe.Truncated) })
                            }
                        }
                    } finally { $sub.Dispose() }
                } else { Skip-Element $reader }
            } elseif ($section -eq 'ResultSummary' -and $reader.LocalName -in @('StdOut', 'StdErr')) {
                Skip-Element $reader
            } elseif ($reader.Depth -eq 1 -and $section -notin @('Results', 'ResultSummary', 'Times')) {
                Skip-Element $reader
            }
        }
        if (-not $seenCounters -or -not $seenSummary) { throw 'missing_summary' }
        if ($null -ne $NotBefore -and -not $seenStart) { throw 'missing_run_time' }
        if ($data.total -eq 0) { throw 'no_tests' }
        foreach ($key in @('total', 'passed', 'failed', 'skipped', 'other')) {
            if ($data[$key] -ne $actual[$key]) { throw 'counter_result_mismatch' }
        }
    } catch {
        $data.invalid = $true
        $code = 'unreadable_or_invalid_xml'
        $known = @('file_too_large', 'not_trx', 'duplicate_summary', 'duplicate_counters', 'invalid_counters',
            'missing_summary', 'missing_run_time', 'stale_run', 'no_tests', 'counter_result_mismatch', 'unsupported_hierarchy')
        if ($_.Exception.Message -in $known) { $code = $_.Exception.Message }
        Add-InputError $data.report $code
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
    }
    [pscustomobject]$data
}

function Emit {
    param([object]$Payload)
    if ($Json) { $Payload | ConvertTo-Json -Depth 6 -Compress; return }
    if ($Mode -eq 'Summary') {
        $parts = [System.Collections.Generic.List[string]]::new()
        $parts.Add($Payload.status.ToUpperInvariant())
        if ($Payload.reports -ne 1) { $parts.Add("reports=$($Payload.reports)") }
        foreach ($key in @('total', 'passed', 'failed', 'skipped')) { $parts.Add("$key=$($Payload.$key)") }
        foreach ($key in @('other', 'runErrors', 'invalid', 'sumReportSeconds')) {
            if ($Payload.Contains($key) -and $Payload[$key] -ne 0) { $parts.Add("$key=$($Payload[$key])") }
        }
        $parts -join ' '
    } else {
        foreach ($row in $Payload.items) {
            $parts = [System.Collections.Generic.List[string]]::new()
            if ($Payload.reports -gt 1) { $parts.Add("[$($row.report)]") }
            if ($Mode -eq 'RunErrors') {
                $parts.Add("$($row.level): $($row.message)")
            } else {
                if ($row.PSObject.Properties['seconds']) { $parts.Add("$($row.seconds)s") }
                if ($row.PSObject.Properties['outcome']) { $parts.Add($row.outcome) }
                $parts.Add($row.test)
                if ($row.PSObject.Properties['message']) { $parts.Add("| $($row.message)") }
                if ($row.PSObject.Properties['stack']) { $parts.Add("| $($row.stack)") }
            }
            if ($row.PSObject.Properties['truncated'] -and $row.truncated) { $parts.Add('[truncated]') }
            $parts -join ' '
        }
        if ($Payload.items.Count -eq 0 -or $Payload.omitted -gt 0 -or $Payload.status -ne 'pass' -or $Payload.Contains('unranked')) {
            $footer = "$($Payload.status.ToUpperInvariant()) matched=$($Payload.matched) shown=$($Payload.items.Count) omitted=$($Payload.omitted)"
            if ($Payload.Contains('unranked')) { $footer += " unranked=$($Payload.unranked)" }
            $footer
        }
    }
    if ($Payload.Contains('errors')) {
        foreach ($item in $Payload.errors) { "INPUT $($item.report): $($item.error)" }
        if ($Payload.invalid -gt $Payload.errors.Count) { "inputErrorsOmitted=$($Payload.invalid - $Payload.errors.Count)" }
    }
}

function Show-Help {
    if ($LastRun -or $RunId) {
        $lines = @('dotcheck -LastRun -JournalPath private.jsonl [-Json]',
            'dotcheck -RunId <GUID|legacy-startedUtc> -JournalPath private.jsonl [-Mode Failed|Detail|RunErrors|Errors|Warnings]',
            'Read-only: never starts dotnet. LastRun selects the last started run, including unfinished runs.',
            'Saved success is rechecked against available TRX; absent evidence never becomes verified success.',
            'Errors/Warnings show bounded retained compiler diagnostics; missing retained data does not prove zero diagnostics.',
            'Build summaries are recorded results, not a new build. Journal limit: MaxLogMiB and 10000 runs.')
        if ($Json) { @{help=$lines} | ConvertTo-Json -Compress } else { $lines }; return
    }
    if ($Build -or $Run -or $Clean) {
        $lines = @(
            'dotcheck -Build -Project app.csproj [-Mode Summary|Errors|Warnings]',
            'dotcheck -Run -Project tests.csproj [-Filter "FullyQualifiedName~Suite"]',
            'Test modes: Summary (auto failures), Failed, Detail -Test substring, Skipped, Slow, RunErrors, Errors, Warnings.',
            '-Configuration Debug; -Framework optional; -NoRestore/-NoBuild only when valid.',
            '-Runner Auto|VSTest|MTP; Auto reads ancestor global.json. MTP requires registered TRX extension.',
            '-DotnetArgs @("..."): extra native options, no shell evaluation. Managed options cannot be overridden.',
            '-TimeoutSeconds 600; -MaxLogMiB 64; -Top 5; -MaxChars 350; -Json for processing.',
            '-MaxWarningDiagnostics 0 enforces zero compiler warnings; default -1 permits warnings.',
            '-JournalPath private.jsonl requires -Reason; records every run without raw custom arguments.',
            '-HeartbeatSeconds 60: optional elapsed-time heartbeat on stderr; default 0 disables it.',
            '-LockRoot defaults to the project worktree; competing dotcheck runs fail before native startup.',
            'Windows owned Job Objects stop child trees, including on runner termination; processTreeCompleted confirms shutdown.',
            'Output ranges (inclusive): -Top 1..100; -MaxChars 32..4096; -StackLines 0..20 (Detail only).',
            '-ResultsDirectory <path>: passes the same option to dotnet test; absent = native default.',
            '-LogPath <file>: optional full private log; absent = no log file. No automatic cleanup.',
            'dotcheck -Clean -ResultsDirectory <path> [-KeepReports 10]: delete older top-level TRX only; run when tests are stopped.',
            'Runner requires PowerShell 7; no standalone build before dotnet test.',
            'Native nonzero exit is preserved; missing/invalid reports after native success = 2; timeout = 124, log limit = 125.'
        )
        if ($Json) { [ordered]@{ help = $lines } | ConvertTo-Json -Compress } else { $lines }
        return
    }
    $lines = @(
        'dotcheck -Path <file.trx|directory> [-Mode Summary|Failed|Skipped|Slow|Detail|RunErrors]',
        'dotcheck -LastRun -JournalPath private.jsonl; -RunId selects a specific recorded run.',
        'Default: one-line Summary. Listings: -Top 5 -MaxChars 350; -Json only for processing.',
        'Output ranges (inclusive): -Top 1..100; -MaxChars 32..4096; -StackLines 0..20 (Detail only).',
        '-Test <literal substring> filters listings; Detail requires it. Stack: -StackLines 3 (Detail only).',
        '-Recurse: directory opt-in. -NotBefore <run-start>: reject old files/runs.',
        '-FailOnSkipped: mandatory gates. Exit 0=healthy, 1=failure, 2=input/report error.',
        'Reader preserves reports. Runner: dotcheck -Help -Run or dotcheck -Help -Build.',
        '-Install: repair owned User PATH entries and this process; -Uninstall: remove owned entries only.',
        '-Help -Mode <mode>: focused examples. New shells are needed after PATH changes made in a child shell.'
    )
    $examples = @{
        Summary = @('dotcheck -Path current.trx', 'dotcheck -Path current.dotcheck -NotBefore $runStart -FailOnSkipped')
        Failed = @('dotcheck -Path current.dotcheck -Mode Failed', 'dotcheck -Path current.dotcheck -Mode Failed -Top 3')
        Skipped = @('dotcheck -Path current.dotcheck -Mode Skipped', 'dotcheck -Path current.dotcheck -Mode Skipped -Test Integration')
        Slow = @('dotcheck -Path current.dotcheck -Mode Slow -Top 3', 'dotcheck -Path current.dotcheck -Mode Slow -Test Namespace -Json')
        Detail = @('dotcheck -Path current.dotcheck -Mode Detail -Test Namespace.TestName', 'dotcheck -Path current.dotcheck -Mode Detail -Test TestName -StackLines 3 -MaxChars 600')
        RunErrors = @('dotcheck -Path current.dotcheck -Mode RunErrors', 'dotcheck -Path current.dotcheck -Mode RunErrors -Top 3')
    }
    if (-not $examples.ContainsKey($Mode)) { throw 'invalid_arguments' }
    if ($script:requestedMode) {
        $lines = @("Mode=$Mode") + $examples[$Mode] + @('Exit: 0=healthy, 1=failure, 2=invalid. Filters never change overall health.')
    } else {
        $installExample = "  & '" + $PSCommandPath.Replace("'", "''") + "' -Install"
        $lines += @('Examples:', '  dotcheck -Path current.dotcheck -Mode Failed', '  dotcheck -Path current.dotcheck -Mode Detail -Test TestName', $installExample)
    }
    if ($Json) { [ordered]@{ help = $lines } | ConvertTo-Json -Compress }
    else { $lines }
}

function Add-ReportFile {
    param([System.IO.FileInfo]$File)
    if ($null -ne $NotBefore -and $File.LastWriteTimeUtc -lt ([datetime]$NotBefore).ToUniversalTime()) {
        return $false
    }
    if ($script:seen.Add($File.FullName)) {
        if ($script:files.Count -ge $MaxFiles) { throw 'too_many_reports' }
        $script:files.Add($File)
    }
    return $true
}

function Get-DotcheckEnv([string]$Name, [string]$Target) {
    [Environment]::GetEnvironmentVariable($Name, $Target)
}
function Set-DotcheckEnv([string]$Name, [AllowNull()][string]$Value, [string]$Target) {
    [Environment]::SetEnvironmentVariable($Name, $Value, $Target)
}
function Normalize-DotcheckPath([AllowNull()][string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    try {
        [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Value.Trim().Trim('"'))).TrimEnd([char[]]@('\', '/'))
    } catch { return '' }
}
function Test-DotcheckOwnedRoot([string]$Root, [string]$FileName) {
    try {
        $file = Join-Path $Root $FileName
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
        $reader = [System.IO.File]::OpenText($file)
        try {
            for ($i = 0; $i -lt 3; $i++) {
                if ($reader.ReadLine() -eq '# dotcheck-tool-id: 48683d33-42bd-4ff8-808f-6a12c8795c89') { return $true }
            }
        } finally { $reader.Dispose() }
    } catch { }
    return $false
}
function Resolve-DotcheckCommand([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command -and $command.CommandType -eq 'ExternalScript') { return $command.Path }
    return ''
}
function Update-DotcheckPath {
    param([string]$Action, [string]$ToolFile)
    if ([System.IO.Path]::DirectorySeparatorChar -ne '\') { throw 'path_action_windows_only' }
    $file = [System.IO.Path]::GetFullPath($ToolFile)
    $root = [System.IO.Path]::GetDirectoryName($file)
    $fileName = [System.IO.Path]::GetFileName($file)
    $commandName = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $old = [ordered]@{
        UserPath = (Get-DotcheckEnv 'Path' 'User')
        ProcessPath = (Get-DotcheckEnv 'Path' 'Process')
        UserFile = (Get-DotcheckEnv 'DOTCHECK_TOOL_FILE' 'User')
        ProcessFile = (Get-DotcheckEnv 'DOTCHECK_TOOL_FILE' 'Process')
        LegacyUserFile = (Get-DotcheckEnv 'TRX_TOOL_FILE' 'User')
        LegacyProcessFile = (Get-DotcheckEnv 'TRX_TOOL_FILE' 'Process')
    }
    $owned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$owned.Add((Normalize-DotcheckPath $root))
    foreach ($previous in @($old.UserFile, $old.ProcessFile, $old.LegacyUserFile, $old.LegacyProcessFile)) {
        if ($previous -and [System.IO.Path]::IsPathRooted($previous)) {
            [void]$owned.Add((Normalize-DotcheckPath ([System.IO.Path]::GetDirectoryName($previous))))
        }
    }
    foreach ($pathValue in @($old.UserPath, $old.ProcessPath)) {
        foreach ($entry in ($pathValue -split ';')) {
            $candidate = Normalize-DotcheckPath $entry
            if ($candidate -and (Test-DotcheckOwnedRoot $candidate $fileName)) { [void]$owned.Add($candidate) }
        }
    }
    $next = [ordered]@{}
    foreach ($key in @('UserPath', 'ProcessPath')) {
        $entries = [System.Collections.Generic.List[string]]::new()
        if ($old[$key]) {
            foreach ($entry in ($old[$key] -split ';')) {
                if (-not $owned.Contains((Normalize-DotcheckPath $entry))) { $entries.Add($entry) }
            }
        }
        if ($Action -eq 'Install') { $entries.Insert(0, $root) }
        $next[$key] = $entries -join ';'
    }
    $next.UserFile = $null
    $next.ProcessFile = $null
    $next.LegacyUserFile = $null
    $next.LegacyProcessFile = $null
    if ($Action -eq 'Install') { $next.UserFile = $file; $next.ProcessFile = $file }
    $written = [System.Collections.Generic.List[string]]::new()
    $mapping = @{
        UserPath = @('Path', 'User'); ProcessPath = @('Path', 'Process')
        UserFile = @('DOTCHECK_TOOL_FILE', 'User'); ProcessFile = @('DOTCHECK_TOOL_FILE', 'Process')
        LegacyUserFile = @('TRX_TOOL_FILE', 'User'); LegacyProcessFile = @('TRX_TOOL_FILE', 'Process')
    }
    try {
        foreach ($key in @('ProcessPath', 'ProcessFile', 'UserPath', 'UserFile', 'LegacyProcessFile', 'LegacyUserFile')) {
            if ($key -eq 'UserPath' -and $Action -eq 'Install' -and
                (Normalize-DotcheckPath (Resolve-DotcheckCommand $commandName)) -ne (Normalize-DotcheckPath $file)) {
                throw 'command_shadowed'
            }
            if ([string]$next[$key] -cne [string]$old[$key]) {
                $written.Add($key)
                Set-DotcheckEnv $mapping[$key][0] $next[$key] $mapping[$key][1]
            }
        }
    } catch {
        $failure = 'path_install_failed'
        if ($_.Exception.Message -eq 'command_shadowed') { $failure = 'command_shadowed' }
        $rollbackFailed = $false
        for ($i = $written.Count - 1; $i -ge 0; $i--) {
            $key = $written[$i]
            try {
                $current = Get-DotcheckEnv $mapping[$key][0] $mapping[$key][1]
                if ([string]$current -ceq [string]$next[$key]) {
                    Set-DotcheckEnv $mapping[$key][0] $old[$key] $mapping[$key][1]
                } elseif ([string]$current -cne [string]$old[$key]) { $rollbackFailed = $true }
            } catch { $rollbackFailed = $true }
        }
        if ($rollbackFailed) { throw 'path_rollback_failed' }
        throw $failure
    }
    [pscustomobject][ordered]@{
        status = $(if ($Action -eq 'Install') { 'installed' } else { 'uninstalled' })
        path = $root
        changed = ([string]$next.UserPath -cne [string]$old.UserPath -or [string]$next.UserFile -cne [string]$old.UserFile)
        restartShell = ([string]$next.UserPath -cne [string]$old.UserPath)
    }
}

function Clear-DotcheckReports {
    Assert-ArgumentRange 'KeepReports' $KeepReports 0 10000
    if (-not $ResultsDirectory) { Stop-InvalidArguments '-Clean requires -ResultsDirectory.' }
    $root = [System.IO.Path]::GetFullPath($ResultsDirectory)
    $item = Get-Item -LiteralPath $root
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'unsafe_run_store' }
    $files = @(Get-ChildItem -LiteralPath $root -Filter '*.trx' -File | Sort-Object LastWriteTimeUtc,Name -Descending)
    $deleted = 0; $skipped = 0
    foreach ($file in @($files | Select-Object -Skip $KeepReports)) {
        $target = [IO.Path]::GetFullPath($file.FullName)
        if ([IO.Path]::GetDirectoryName($target) -ne $root) { throw 'unsafe_run_store' }
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { $skipped++; continue }
        try {
            # Exclusive delete-on-close prevents deleting a report held open by a test runner.
            $handle = [IO.FileStream]::new($target, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
            $handle.Dispose()
            $deleted++
        } catch { $skipped++ }
    }
    [pscustomobject]@{ deleted = $deleted; skipped = $skipped }
}
function Add-NativeLine {
    param([string]$Line, [object]$State, [System.IO.StreamWriter]$Writer)
    $bytes = [System.Text.Encoding]::UTF8.GetByteCount($Line) + 2
    if ($State.bytes + $bytes -gt [long]$MaxLogMiB * 1024 * 1024) { return $false }
    if ($null -ne $Writer) { $Writer.WriteLine($Line) }
    $State.bytes += $bytes
    if (-not $Line.Trim()) { return $true }
    if ($Line -match '^\s*Results File:\s*(.+\.trx)\s*$') {
        [void]$State.reportPaths.Add($Matches[1].Trim())
    }
    $bounded = $Line
    if ($bounded.Length -gt 8192) { $bounded = $bounded.Substring(0, 8192) }
    $safe = Safe-Text $bounded
    $State.tail.Add($safe.Text)
    if ($State.tail.Count -gt $Top) { $State.tail.RemoveAt(0) }
    if ($bounded -match '^\s*(?:(?<where>.*?)\s*:\s*)?(?<level>error|warning)\s+(?<code>[A-Za-z]+\d+)\s*:\s*(?<message>.*)$') {
        $level = $Matches.level.ToLowerInvariant()
        $location = $Matches['where']
        $message = $Matches.message
        $code = $Matches.code
        # Fixed-size dedup keys; retain only -Top messages per severity.
        $hash = [System.Security.Cryptography.SHA256]::Create()
        try { $key = [Convert]::ToBase64String($hash.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Line))) }
        finally { $hash.Dispose() }
        if ($State.seen.Add($key)) {
            $State[$level + 'Count']++
            if ($State[$level + 's'].Count -lt $Top) {
                $State[$level + 's'].Add([pscustomobject]@{
                    level = $level; code = $code; location = (Safe-Text $location).Text; message = (Safe-Text $message).Text
                })
            }
        }
    }
    return $true
}
function Initialize-OwnedProcessJob {
# Windows Job Object: kernel owns the complete child tree, including on runner termination.
if (-not ('DotcheckOwnedJob' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public sealed class DotcheckOwnedJob : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long PerProcess, PerJob; public uint Flags; public UIntPtr Min, Max;
        public uint Active; public UIntPtr Affinity; public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong A,B,C,D,E,F; }
    [StructLayout(LayoutKind.Sequential)] struct Limits {
        public BasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob;
    }
    [StructLayout(LayoutKind.Sequential)] struct Accounting {
        public long A,B,C,D; public uint Faults, Total, Active, Terminated;
    }
    [DllImport("kernel32", SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int cls, ref Limits limits, uint size);
    [DllImport("kernel32", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int cls, out Accounting accounting, uint size, IntPtr returned);
    [DllImport("kernel32", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32")] static extern bool CloseHandle(IntPtr handle);
    IntPtr handle;
    public DotcheckOwnedJob() {
        handle = CreateJobObject(IntPtr.Zero, null);
        var limits = new Limits(); limits.Basic.Flags = 0x2000; // KILL_ON_JOB_CLOSE
        if(handle == IntPtr.Zero || !SetInformationJobObject(handle,9,ref limits,(uint)Marshal.SizeOf<Limits>())) {
            Dispose(); throw new InvalidOperationException("owned_job_creation_failed");
        }
    }
    public void Attach(Process process) {
        if(!AssignProcessToJobObject(handle, process.Handle)) throw new InvalidOperationException("owned_job_assignment_failed");
    }
    public uint Active {
        get {
            Accounting data;
            if(!QueryInformationJobObject(handle,1,out data,(uint)Marshal.SizeOf<Accounting>(),IntPtr.Zero))
                throw new InvalidOperationException("owned_job_query_failed");
            return data.Active;
        }
    }
    public bool StopAndWait(int milliseconds) {
        if(Active != 0 && !TerminateJobObject(handle,1)) return false;
        var timer = Stopwatch.StartNew();
        while(Active != 0 && timer.ElapsedMilliseconds < milliseconds) System.Threading.Thread.Sleep(25);
        return Active == 0;
    }
    public void Dispose() { if(handle != IntPtr.Zero) { CloseHandle(handle); handle=IntPtr.Zero; } }
}
'@
}
}

function New-JournalMutex {
    param([string]$File)
    $canonical = [IO.Path]::GetFullPath($File)
    if ([IO.Path]::DirectorySeparatorChar -eq '\') { $canonical = $canonical.ToLowerInvariant() }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $key = [Convert]::ToBase64String($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('/','_') }
    finally { $hash.Dispose() }
    return [Threading.Mutex]::new($false, "dotcheck-journal-$key")
}

function Write-JournalEntry {
    param([string]$File, [object]$Entry)
    # Separate journal lock also protects refused runs and different worktrees sharing a journal.
    $mutex = New-JournalMutex $File
    $taken = $false
    try {
        try { $taken = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $taken = $true }
        if (-not $taken) { throw 'journal_write_failed' }
        [IO.File]::AppendAllText([IO.Path]::GetFullPath($File), ($Entry | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false))
    } finally { if ($taken) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Invoke-DotcheckDotnet {
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'runner_requires_powershell_7' }
    Assert-ArgumentRange 'TimeoutSeconds' $TimeoutSeconds 1 86400
    Assert-ArgumentRange 'MaxFiles' $MaxFiles 1 10000
    Assert-ArgumentRange 'MaxFileMiB' $MaxFileMiB 1 1024
    Assert-ArgumentRange 'MaxLogMiB' $MaxLogMiB 1 1024
    Assert-ArgumentRange 'HeartbeatSeconds' $HeartbeatSeconds 0 86400
    if ($Path.Count) { Stop-InvalidArguments '-Build/-Run cannot be combined with -Path; use -Project.' }
    if ($JournalPath -and -not $Reason.Trim()) { Stop-InvalidArguments '-JournalPath requires a concrete -Reason.' }
    if ($Runner -notin @('Auto', 'VSTest', 'MTP')) { Stop-InvalidArguments '-Runner must be Auto, VSTest or MTP.' }
    if (
        ($Build -and ($NoBuild -or $Filter -or $Test -or $ResultsDirectory -or $Mode -notin @('Summary', 'Errors', 'Warnings'))) -or
        ($Mode -ne 'Detail' -and $StackLines -gt 0) -or
        ($Mode -eq 'RunErrors' -and $Test) -or
        ($Run -and ($Mode -notin @('Summary','Failed','Skipped','Slow','Detail','RunErrors','Errors','Warnings') -or
            ($Mode -eq 'Detail' -and -not $Test)))) { throw 'invalid_arguments' }
    foreach ($argument in $DotnetArgs) {
        if ($argument -match '^(-l|--logger|--results-directory|--report-trx(?:-filename)?|--project|--solution|--no-build|--no-restore|--filter|--configuration|-c|--framework|-f)(?:$|[:=])' -or $argument -eq '--') {
            throw 'managed_argument_override'
        }
    }
    $item = Get-Item -LiteralPath $Project -ErrorAction Stop
    $working = (Get-Location).ProviderPath
    $selectedRunner = $Runner
    if ($selectedRunner -eq 'Auto') {
        $selectedRunner = 'VSTest'
        $ancestor = [System.IO.DirectoryInfo]::new($working)
        while ($null -ne $ancestor) {
            $config = Join-Path $ancestor.FullName 'global.json'
            if (Test-Path -LiteralPath $config) {
                $global = [System.IO.File]::ReadAllText($config) | ConvertFrom-Json
                if ($global.PSObject.Properties['test'] -and $global.test.PSObject.Properties['runner'] -and
                    $global.test.runner -eq 'Microsoft.Testing.Platform') { $selectedRunner = 'MTP' }
                break
            }
            $ancestor = $ancestor.Parent
        }
    }
    $command = Get-Command dotnet -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $directory = ''
    if ($ResultsDirectory) { $directory = [System.IO.Path]::GetFullPath($ResultsDirectory) }
    $writer = $null; $process = $null; $job = $null; $mutex = $null; $lockTaken = $false
    $treeCompleted = $null; $processStarted = $false
    $journalStarted = $false
    $nativeExit = 2; $condition = ''
    $state = @{
        bytes = 0L; errorCount = 0; warningCount = 0
        seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        errors = [System.Collections.Generic.List[object]]::new()
        warnings = [System.Collections.Generic.List[object]]::new()
        tail = [System.Collections.Generic.List[string]]::new()
        reportPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    }
    $started = [datetime]::UtcNow
    $invocationId = [guid]::NewGuid().ToString('D')
    $nextHeartbeat = $HeartbeatSeconds
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $argsList = [System.Collections.Generic.List[string]]::new()
    try {
        if ($JournalPath) {
            $journalFull = [System.IO.Path]::GetFullPath($JournalPath)
            if (-not (Test-Path -LiteralPath (Split-Path $journalFull) -PathType Container)) { throw 'journal_parent_missing' }
            Write-JournalEntry $journalFull ([ordered]@{ schemaVersion = 1; toolVersion = $script:toolVersion; runId = $invocationId;
                event = 'started'; startedUtc = $started.ToString('o'); project = $item.FullName;
                reason = (Safe-Text $Reason).Text; filter = (Safe-Text $Filter).Text;
                configuration = $Configuration; framework = $Framework; noBuild = [bool]$NoBuild;
                noRestore = [bool]$NoRestore; runner = $selectedRunner; timeoutSeconds = $TimeoutSeconds;
                verb = $(if ($Build) { 'build' } else { 'test' }); dotnetArgumentCount = $DotnetArgs.Count })
            $journalStarted = $true
        }
        $lockDirectory = $LockRoot
        if (-not $lockDirectory) {
            $ancestor = if ($item.PSIsContainer) { [System.IO.DirectoryInfo]::new($item.FullName) } else { $item.Directory }
            $lockDirectory = $ancestor.FullName
            while ($null -ne $ancestor) {
                if (Test-Path -LiteralPath (Join-Path $ancestor.FullName '.git')) { $lockDirectory = $ancestor.FullName; break }
                $ancestor = $ancestor.Parent
            }
        }
        $lockKey = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
            [System.Text.Encoding]::UTF8.GetBytes([System.IO.Path]::GetFullPath($lockDirectory).ToLowerInvariant())))
        $mutex = [System.Threading.Mutex]::new($false, "dotcheck-$lockKey")
        try { $lockTaken = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $lockTaken = $true }
        if (-not $lockTaken) { throw 'build_outputs_busy' }
        if ($IsWindows) {
            Initialize-OwnedProcessJob
            $job = [DotcheckOwnedJob]::new()
        }
        $verb = 'test'
        if ($Build) { $verb = 'build' }
        $argsList.Add($verb)
        if ($Run -and $selectedRunner -eq 'MTP') {
            if ($item.PSIsContainer) { throw 'mtp_requires_explicit_project' }
            if ($item.Extension -in @('.sln','.slnx')) { $argsList.Add('--solution') }
            else { $argsList.Add('--project') }
        }
        $argsList.Add($item.FullName)
        $argsList.Add('--configuration'); $argsList.Add($Configuration)
        $argsList.Add('--verbosity'); $argsList.Add('quiet')
        if ($Framework) { $argsList.Add('--framework'); $argsList.Add($Framework) }
        if ($NoRestore) { $argsList.Add('--no-restore') }
        if ($NoBuild) { $argsList.Add('--no-build') }
        if ($Build -or $selectedRunner -eq 'VSTest') {
            $argsList.Add('-m:1'); $argsList.Add('/nodeReuse:false'); $argsList.Add('--tl:off')
        }
        if ($Run) {
            if ($directory) { $argsList.Add('--results-directory'); $argsList.Add($directory) }
            if ($selectedRunner -eq 'VSTest') {
                $argsList.Add('--logger'); $argsList.Add('trx')
                $argsList.Add('--logger'); $argsList.Add('console;verbosity=minimal')
                if ($Filter) { $argsList.Add('--filter'); $argsList.Add($Filter) }
            }
        }
        foreach ($argument in $DotnetArgs) { $argsList.Add($argument) }
        if ($Run -and $selectedRunner -eq 'MTP') {
            $argsList.Add('--'); $argsList.Add('--report-trx')
            if ($Filter) { $argsList.Add('--filter'); $argsList.Add($Filter) }
        }
        $info = [System.Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $command.Source
        $info.WorkingDirectory = $working
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $info.Environment['DOTNET_CLI_UI_LANGUAGE'] = 'en'
        $info.Environment['DOTNET_NOLOGO'] = '1'
        $info.Environment['DOTNET_CLI_USE_MSBUILD_SERVER'] = '0'
        $info.Environment['MSBUILDDISABLENODEREUSE'] = '1'
        foreach ($argument in $argsList) { $info.ArgumentList.Add($argument) }
        if ($LogPath) {
            # Never overwrite an existing file or test report.
            $stream = [System.IO.File]::Open([System.IO.Path]::GetFullPath($LogPath), 'CreateNew', 'Write', 'Read')
            $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
        }
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $info
        [void]$process.Start()
        $processStarted = $true
        if ($null -ne $job) { $job.Attach($process) }
        $outTask = $process.StandardOutput.ReadLineAsync()
        $errTask = $process.StandardError.ReadLineAsync()
        while ($null -ne $outTask -or $null -ne $errTask -or -not $process.HasExited) {
            if ($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds) { $condition = 'timeout'; $nativeExit = 124; break }
            if ($HeartbeatSeconds -gt 0 -and $timer.Elapsed.TotalSeconds -ge $nextHeartbeat) {
                [Console]::Error.WriteLine('RUNNING elapsed={0}s', [int]$timer.Elapsed.TotalSeconds)
                $nextHeartbeat = $timer.Elapsed.TotalSeconds + $HeartbeatSeconds
            }
            $pending = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
            if ($null -ne $outTask) { $pending.Add($outTask) }
            if ($null -ne $errTask) { $pending.Add($errTask) }
            if ($pending.Count) { [void][System.Threading.Tasks.Task]::WaitAny($pending.ToArray(), 100) }
            else { [System.Threading.Thread]::Sleep(20) }
            foreach ($stream in @('out', 'err')) {
                $task = $outTask
                if ($stream -eq 'err') { $task = $errTask }
                if ($null -ne $task -and $task.IsCompleted) {
                    $line = $task.GetAwaiter().GetResult()
                    if ($null -ne $line -and -not (Add-NativeLine $line $state $writer)) {
                        $condition = 'log_limit'; $nativeExit = 125; break
                    }
                    $nextTask = $null
                    if ($null -ne $line) {
                        if ($stream -eq 'out') { $nextTask = $process.StandardOutput.ReadLineAsync() }
                        else { $nextTask = $process.StandardError.ReadLineAsync() }
                    }
                    if ($stream -eq 'out') { $outTask = $nextTask } else { $errTask = $nextTask }
                }
            }
            if ($condition) { break }
        }
        if (-not $condition) { $process.WaitForExit(); $nativeExit = $process.ExitCode }
    } catch {
        [void](Add-NativeLine ("runner_exception: " + (Safe-Text $_.Exception.Message).Text) $state $writer)
        $condition = 'cannot_run_dotnet'
        if ($_.Exception.Message -in @('mtp_requires_explicit_project','build_outputs_busy','journal_parent_missing',
            'owned_job_creation_failed','owned_job_assignment_failed','owned_job_query_failed','journal_write_failed')) { $condition = $_.Exception.Message }
        if ($JournalPath -and -not $journalStarted -and $condition -eq 'cannot_run_dotnet') { $condition = 'journal_write_failed' }
        $nativeExit = 2
    } finally {
        if ($null -ne $process -and $processStarted) {
            try {
                if ($null -ne $job) { $treeCompleted = $job.StopAndWait(5000) }
                if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
            } catch {
                [void](Add-NativeLine ("cleanup_exception: " + (Safe-Text $_.Exception.Message).Text) $state $writer)
                $treeCompleted = $false
            }
            $process.Dispose()
        }
        elseif ($null -ne $process) { $process.Dispose() }
        if ($null -ne $job) { $job.Dispose() }
        if ($null -ne $mutex) {
            if ($lockTaken) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
        if ($null -ne $writer) { $writer.Dispose() }
        $timer.Stop()
    }
    $requested = $Mode
    $phase = 'BUILD'
    $totals = [ordered]@{ total = 0L; passed = 0L; failed = 0L; skipped = 0L; other = 0L }
    $reportExit = 0
    $reportErrors = @()
    $abortedRun = $false
    $runLevelFailure = $false
    if ($Run) {
        $phase = 'TEST'
        $NotBefore = $started
        $Mode = $requested
        if ($requested -in @('Summary','Errors','Warnings')) { $Mode = 'Failed'; $script:includeFailureMessages = $true }
        if (-not $directory -and -not $item.PSIsContainer -and $item.Extension -eq '.csproj' -and $selectedRunner -eq 'VSTest') {
            $directory = Join-Path $item.DirectoryName 'TestResults'
        }
        if (-not $state.reportPaths.Count -and $directory -and (Test-Path -LiteralPath $directory -PathType Container)) {
            foreach ($file in Get-ChildItem -LiteralPath $directory -Filter '*.trx' -File) {
                if ($file.LastWriteTimeUtc -ge $started) { [void]$state.reportPaths.Add($file.FullName) }
            }
        }
        $files = @()
        try {
            $files = @($state.reportPaths | ForEach-Object { Get-Item -LiteralPath $_ } | Where-Object { $_.LastWriteTimeUtc -ge $started })
        } catch { $reportExit = 2; $reportErrors += 'unreadable_report' }
        if ($files.Count -gt $MaxFiles) { $reportExit = 2; $reportErrors += 'too_many_reports'; $files = @() }
        if (-not $files.Count) { $reportExit = 2; $reportErrors = @('missing_trx') }
        foreach ($file in $files) {
            $report = Read-Report $file
            if ($report.runOutcome -eq 'Aborted') { $abortedRun = $true }
            if ($report.runErrors -gt 0 -or ($report.badRun -and $report.failed -eq 0)) { $runLevelFailure = $true }
            foreach ($key in $totals.Keys.Clone()) { $totals[$key] += $report.$key }
            if ($report.invalid) { $reportExit = 2 }
            elseif (($report.badRun -or $report.failed -or $report.other -or ($FailOnSkipped -and $report.skipped)) -and $reportExit -ne 2) { $reportExit = 1 }
        }
        $Mode = $requested
        $script:includeFailureMessages = $false
        if ($requested -eq 'Detail' -and -not $script:matched) { $reportExit = 2; $reportErrors += 'test_not_found' }
        if ($script:inputErrors.Count) { $reportErrors += @($script:inputErrors | ForEach-Object error) }
    }
    $exitCode = $nativeExit
    if ($exitCode -eq 0) { $exitCode = $reportExit }
    $diagnosticsExceeded = $MaxWarningDiagnostics -ge 0 -and $state.warningCount -gt $MaxWarningDiagnostics
    if ($exitCode -eq 0 -and $diagnosticsExceeded) { $exitCode = 1 }
    if ($treeCompleted -eq $false) { $condition = 'process_tree_unfinished'; if ($exitCode -eq 0) { $exitCode = 1 } }
    $outcome = 'passed'
    if ($condition -eq 'timeout') { $outcome = 'timeout' }
    elseif ($state.errorCount) { $outcome = 'build_failed' }
    elseif ($abortedRun) { $outcome = 'aborted' }
    elseif ($reportExit -eq 2 -and $Run -and -not $condition) { $outcome = 'report_invalid' }
    elseif ($condition) { $outcome = 'runner_failed' }
    elseif ($runLevelFailure) { $outcome = 'test_run_failed' }
    elseif ($Run -and ($nativeExit -ne 0 -or $reportExit -ne 0)) { $outcome = 'tests_failed' }
    elseif ($nativeExit -ne 0) { $outcome = 'build_failed' }
    elseif ($diagnosticsExceeded) { $outcome = 'diagnostics_exceeded' }
    $status = 'pass'
    if ($exitCode) { $status = 'fail' }
    if ($nativeExit -eq 0 -and $reportExit -eq 2) { $status = 'invalid' }
    $payload = [ordered]@{ phase = $phase; status = $status; exit = $exitCode; nativeExit = $nativeExit; seconds = [Math]::Round($timer.Elapsed.TotalSeconds,3) }
    $payload.outcome = $outcome
    $payload.runId = $invocationId
    $payload.processTreeCompleted = $treeCompleted
    if ($diagnosticsExceeded) { $payload.maxWarningDiagnostics = $MaxWarningDiagnostics }
    if ($Run) { $payload.reports = @($files | ForEach-Object FullName) }
    if ($LogPath) { $payload.log = [System.IO.Path]::GetFullPath($LogPath) }
    if ($Run) { foreach ($key in $totals.Keys) { $payload[$key] = $totals[$key] } }
    $payload.warningDiagnostics = $state.warningCount
    if ($state.errorCount) { $payload.errorDiagnostics = $state.errorCount }
    if ($condition) { $payload.condition = $condition }
    if ($reportErrors.Count) { $payload.reportErrors = @($reportErrors | Select-Object -Unique) }
    $items = @()
    if ($requested -eq 'Warnings') { $items = @($state.warnings.ToArray()); $payload.omitted = $state.warningCount - $items.Count }
    elseif ($requested -eq 'Errors' -or ($exitCode -ne 0 -and $state.errorCount)) {
        $items = @($state.errors.ToArray()); $payload.omitted = $state.errorCount - $items.Count
    } elseif ($Run -and ($requested -ne 'Summary' -or $exitCode)) {
        $items = @($script:rows.ToArray())
        $payload.omitted = $script:matched - $items.Count
        if ($requested -eq 'Slow') { foreach ($row in $items) { $row.seconds = [Math]::Round($row.seconds,3) } }
        if ($script:unranked) { $payload.unranked = $script:unranked }
    }
    if ($items.Count) { $payload.items = $items }
    if ($exitCode -ne 0 -and -not $items.Count) { $payload.diagnostics = @($state.tail.ToArray()) }
    if ($JournalPath -and $journalStarted) {
        $entry = [ordered]@{ schemaVersion = 1; toolVersion = $script:toolVersion; runId = $invocationId;
            event = 'finished'; startedUtc = $started.ToString('o'); finishedUtc = [datetime]::UtcNow.ToString('o'); reason = (Safe-Text $Reason).Text;
            project = $item.FullName; filter = (Safe-Text $Filter).Text; configuration = $Configuration;
            framework = $Framework; noBuild = [bool]$NoBuild; noRestore = [bool]$NoRestore;
            runner = $selectedRunner; timeoutSeconds = $TimeoutSeconds;
            verb = $(if ($Build) { 'build' } else { 'test' }); dotnetArgumentCount = $DotnetArgs.Count; result = $payload }
        try { Write-JournalEntry $JournalPath $entry }
        catch { $exitCode = 2; $payload.exit = 2; $payload.status = 'fail'; $payload.outcome = 'runner_failed'; $payload.condition = 'journal_write_failed' }
    }
    if ($Json) { $payload | ConvertTo-Json -Depth 6 -Compress }
    else {
        $summary = "$phase $($payload.status.ToUpperInvariant()) outcome=$($payload.outcome) treeCompleted=$treeCompleted"
        if ($Run) { $summary += " total=$($totals.total) passed=$($totals.passed) failed=$($totals.failed) skipped=$($totals.skipped)" }
        $summary += " warningDiagnostics=$($state.warningCount) seconds=$($payload.seconds)"
        if ($exitCode) { $summary += " exit=$exitCode" }
        if ($condition) { $summary += " $condition" }
        if ($reportErrors.Count) { $summary += " report=$($reportErrors -join ',')" }
        $summary
        foreach ($entry in $items) {
            $parts = [System.Collections.Generic.List[string]]::new()
            foreach ($key in @('code','location','outcome','test','message','stack','level','seconds')) {
                if ($entry.PSObject.Properties[$key]) { $parts.Add([string]$entry.$key) }
            }
            if ($entry.PSObject.Properties['truncated'] -and $entry.truncated) { $parts.Add('[truncated]') }
            $parts -join ' | '
        }
        if ($payload.Contains('omitted') -and $payload.omitted) { "omitted=$($payload.omitted)" }
        if ($payload.Contains('unranked')) { "unranked=$($payload.unranked)" }
        if ($payload.Contains('diagnostics')) { $payload.diagnostics }
    }
    return $exitCode
}

function Read-JournalRun {
    # Parse a bounded consistent snapshot outside the journal lock; inspection cannot block writers for parsing time.
    if (-not $JournalPath -or $Path.Count -or $NotBefore -or $Recurse -or $HeartbeatSeconds -or
        $Reason -or $LogPath -or $ResultsDirectory -or $NoBuild -or $NoRestore -or $Filter -or $LockRoot -or
        $DotnetArgs.Count -or ($LastRun -and $RunId)) { throw 'invalid_arguments' }
    if ($Mode -notin @('Summary','Failed','Skipped','Slow','Detail','RunErrors','Errors','Warnings') -or
        ($Mode -eq 'Detail' -and -not $Test) -or ($Mode -in @('Summary','RunErrors') -and $Test) -or
        ($Mode -in @('Errors','Warnings') -and $Test) -or
        ($Mode -ne 'Detail' -and $StackLines -gt 0)) { throw 'invalid_arguments' }
    Assert-ArgumentRange 'MaxLogMiB' $MaxLogMiB 1 1024
    $journalMutex = New-JournalMutex $JournalPath
    $journalTaken = $false
    try {
        try { $journalTaken = $journalMutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $journalTaken = $true }
        if (-not $journalTaken) { throw 'journal_busy' }
        $journal = Get-Item -LiteralPath $JournalPath
        if ($journal.PSIsContainer -or $journal.Length -gt [long]$MaxLogMiB * 1024 * 1024) { throw 'invalid_journal' }
        $snapshot = [IO.File]::ReadAllText($journal.FullName)
    } finally { if ($journalTaken) { $journalMutex.ReleaseMutex() }; $journalMutex.Dispose() }
    $runs = @{}; $latest = $null
    $reader = [IO.StringReader]::new($snapshot)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line.Trim()) { continue }
            try { $entry = $line | ConvertFrom-Json -ErrorAction Stop } catch { throw 'invalid_journal' }
            if (-not $entry.PSObject.Properties['event'] -or -not $entry.PSObject.Properties['startedUtc']) { throw 'invalid_journal' }
            if ($entry.PSObject.Properties['schemaVersion'] -and $entry.schemaVersion -ne 1) { throw 'unsupported_journal_schema' }
            $time = [datetimeoffset]::MinValue
            $timeText = [string]$entry.startedUtc
            if ($entry.startedUtc -is [datetime]) { $timeText = $entry.startedUtc.ToString('o') }
            if (-not [datetimeoffset]::TryParse($timeText, [ref]$time)) { throw 'invalid_journal' }
            $key = $time.ToUniversalTime().ToString('o')
            if ($entry.PSObject.Properties['runId']) {
                $id = [guid]::Empty
                if (-not [guid]::TryParse([string]$entry.runId, [ref]$id) -or $id -eq [guid]::Empty) { throw 'invalid_journal' }
                $key = $id.ToString('D')
            }
            if ($entry.event -eq 'started') {
                if ($runs.ContainsKey($key) -or $runs.Count -ge 10000) { throw 'invalid_journal' }
                $runs[$key] = @{ start = $entry; finish = $null }; $latest = $key
            } elseif ($entry.event -eq 'finished') {
                # 1.1.0 (and older) could emit only finished when the worktree lock refused startup.
                # Recognize only this known failed case; never synthesize a successful or uncertain start.
                if (-not $runs.ContainsKey($key) -and $entry.PSObject.Properties['result'] -and
                    (-not $entry.PSObject.Properties['toolVersion'] -or $entry.toolVersion -eq '1.1.0')) {
                    $legacy = $entry.result
                    if ($legacy.PSObject.Properties['condition'] -and $legacy.condition -eq 'build_outputs_busy' -and
                        $legacy.PSObject.Properties['exit'] -and $legacy.exit -eq 2 -and
                        $legacy.PSObject.Properties['status'] -and $legacy.status -eq 'fail' -and
                        $legacy.PSObject.Properties['outcome'] -and $legacy.outcome -eq 'runner_failed' -and
                        $legacy.PSObject.Properties['processTreeCompleted'] -and $null -eq $legacy.processTreeCompleted) {
                        if ($runs.Count -ge 10000) { throw 'invalid_journal' }
                        $runs[$key] = @{ start = $entry; finish = $null; startEventMissing = $true }; $latest = $key
                    }
                }
                if (-not $runs.ContainsKey($key) -or $null -ne $runs[$key].finish -or
                    $runs[$key].start.startedUtc -ne $entry.startedUtc -or -not $entry.PSObject.Properties['result']) { throw 'invalid_journal' }
                $runs[$key].finish = $entry
            } else { throw 'invalid_journal' }
        }
    } finally { $reader.Dispose() }
    $selected = $latest
    if ($RunId) {
        $selected = $RunId
        $legacyTime = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse($RunId, [ref]$legacyTime)) { $selected = $legacyTime.ToUniversalTime().ToString('o') }
    }
    if (-not $selected -or -not $runs.ContainsKey($selected)) { throw 'journal_run_not_found' }
    $record = $runs[$selected]; $exitCode = 1
    $payload = [ordered]@{ runId = $selected; startedUtc = $record.start.startedUtc;
        status = 'unconfirmed'; outcome = 'unfinished'; reportVerification = 'not_attempted' }
    if ($record.ContainsKey('startEventMissing')) { $payload.startEventMissing = $true }
    foreach ($field in @('project','reason','filter','configuration','framework','runner','verb')) {
        if ($record.start.PSObject.Properties[$field]) { $payload[$field] = (Safe-Text ([string]$record.start.$field)).Text }
    }
    if ($null -ne $record.finish) {
        $saved = $record.finish.result
        if (-not $saved.PSObject.Properties['exit'] -or -not $saved.PSObject.Properties['status'] -or
            -not $saved.PSObject.Properties['outcome']) { throw 'invalid_journal' }
        $exitCode = 0
        if (-not [int]::TryParse([string]$saved.exit, [ref]$exitCode) -or
            $saved.status -notin @('pass','fail','invalid') -or ($exitCode -eq 0 -and $saved.status -ne 'pass') -or
            ($exitCode -ne 0 -and $saved.status -eq 'pass')) { throw 'invalid_journal' }
        $payload.status = $saved.status; $payload.outcome = (Safe-Text ([string]$saved.outcome)).Text
        $payload.recordedExit = $exitCode
        foreach ($field in @('seconds','total','passed','failed','skipped','warningDiagnostics','errorDiagnostics','nativeExit','processTreeCompleted')) {
            if (-not $saved.PSObject.Properties[$field]) { continue }
            $value = $saved.$field
            if ($field -eq 'processTreeCompleted') {
                if ($null -ne $value -and $value -isnot [bool]) { throw 'invalid_journal' }
            } elseif ($field -eq 'seconds') {
                $number = 0.0
                if (-not [double]::TryParse([string]$value, [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or $number -lt 0 -or
                    [double]::IsNaN($number) -or [double]::IsInfinity($number)) { throw 'invalid_journal' }
                $value = $number
            } else {
                $number = 0L
                if (-not [long]::TryParse([string]$value, [ref]$number) -or ($field -ne 'nativeExit' -and $number -lt 0)) { throw 'invalid_journal' }
                $value = $number
            }
            $payload[$field] = $value
        }
        if ($saved.PSObject.Properties['processTreeCompleted'] -and $saved.processTreeCompleted -eq $false) { $exitCode = 1; $payload.status = 'fail' }
        $diagnostics = [System.Collections.Generic.List[object]]::new()
        if ($saved.PSObject.Properties['items']) {
            foreach ($item in @($saved.items)) {
                if (-not $item.PSObject.Properties['code']) { continue }
                $level = 'unknown'
                if ($item.PSObject.Properties['level'] -and $item.level -in @('error','warning')) { $level = $item.level }
                elseif ($payload.Contains('errorDiagnostics') -and $payload.errorDiagnostics -gt 0 -and
                    $payload.Contains('warningDiagnostics') -and $payload.warningDiagnostics -eq 0 -and $saved.outcome -eq 'build_failed') { $level = 'error' }
                elseif ($saved.outcome -eq 'passed' -or $saved.outcome -eq 'diagnostics_exceeded') { $level = 'warning' }
                if (($Mode -eq 'Errors' -and $level -ne 'error') -or ($Mode -eq 'Warnings' -and $level -ne 'warning')) { continue }
                $row = [ordered]@{ level = $level }
                foreach ($field in @('code','location','message')) {
                    if ($item.PSObject.Properties[$field]) { $row[$field] = (Safe-Text ([string]$item.$field)).Text }
                }
                if ($diagnostics.Count -lt $Top) { $diagnostics.Add([pscustomobject]$row) }
            }
        }
        if ($diagnostics.Count -and ($Mode -in @('Errors','Warnings') -or ($Mode -eq 'Summary' -and $exitCode -ne 0))) {
            $payload.recordedDiagnostics = @($diagnostics.ToArray())
        } elseif ($Mode -eq 'Summary' -and $exitCode -ne 0 -and $saved.PSObject.Properties['diagnostics']) {
            $payload.recordedDiagnostics = @($saved.diagnostics | Select-Object -First $Top | ForEach-Object {
                [pscustomobject]@{ message = (Safe-Text ([string]$_)).Text }
            })
        }
        if ($Mode -in @('Errors','Warnings')) {
            $payload.diagnosticsAvailable = $diagnostics.Count -gt 0
            # Absence of retained diagnostics does not mean zero diagnostics in the original run.
        }
        if ($saved.PSObject.Properties['log']) {
            $payload.log = (Safe-Text ([string]$saved.log)).Text
            $payload.logAvailable = Test-Path -LiteralPath ([string]$saved.log) -PathType Leaf
        }
        $reports = @()
        if ($saved.PSObject.Properties['reports']) { $reports = @($saved.reports) }
        $payload.reports = @($reports | ForEach-Object { (Safe-Text ([string]$_)).Text })
        if ($reports.Count) {
            $readerMode = $Mode
            if ($Mode -in @('Errors','Warnings')) { $readerMode = 'Summary' }
            $inspectionArgs = @{ Path = $reports; Mode = $readerMode; Json = $true; Top = $Top; MaxChars = $MaxChars;
                MaxFiles = $MaxFiles; MaxFileMiB = $MaxFileMiB; NotBefore = [datetime]$record.start.startedUtc }
            if ($FailOnSkipped) { $inspectionArgs.FailOnSkipped = $true }
            if ($Test) { $inspectionArgs.Test = $Test }
            if ($StackLines) { $inspectionArgs.StackLines = $StackLines }
            $inspection = & $PSCommandPath @inspectionArgs
            $reportExit = $LASTEXITCODE
            $payload.inspection = $inspection | ConvertFrom-Json
            $payload.reportVerification = 'checked'
            if ($reportExit -ne 0) {
                if ($exitCode -eq 0) { $exitCode = $reportExit }
                $payload.status = $(if ($exitCode -eq 2) { 'invalid' } else { 'fail' }); $payload.reportVerification = 'failed'
            }
        } elseif (($record.start.PSObject.Properties['verb'] -and $record.start.verb -eq 'build') -or
            ($record.finish.PSObject.Properties['verb'] -and $record.finish.verb -eq 'build') -or
            ($saved.PSObject.Properties['phase'] -and $saved.phase -eq 'BUILD')) {
            $payload.reportVerification = 'not_applicable'
            if ($Mode -notin @('Summary','Errors','Warnings')) { throw 'journal_run_has_no_reports' }
        } else {
            $payload.reportVerification = 'unavailable'
            if ($exitCode -eq 0) { $exitCode = 2; $payload.status = 'invalid' }
            if ($Mode -notin @('Summary','Errors','Warnings')) { throw 'journal_run_has_no_reports' }
        }
    }
    $payload.exit = $exitCode
    if ($Json) { $payload | ConvertTo-Json -Depth 12 -Compress }
    else {
        "RUN $($payload.status.ToUpperInvariant()) id=$selected outcome=$($payload.outcome) reportVerification=$($payload.reportVerification) exit=$exitCode"
        if ($payload.Contains('startEventMissing')) { 'Legacy refused run: no started event was recorded.' }
        if ($payload.Contains('inspection') -and $payload.inspection.PSObject.Properties['items']) {
            foreach ($row in @($payload.inspection.items)) {
                foreach ($field in @('test','level','outcome','message','stack','seconds')) {
                    if ($row.PSObject.Properties[$field]) { "$field=$($row.$field)" }
                }
            }
        }
        if ($payload.Contains('recordedDiagnostics')) {
            foreach ($row in $payload.recordedDiagnostics) {
                $parts = [System.Collections.Generic.List[string]]::new()
                foreach ($field in @('level','code','location','message')) {
                    if ($row.PSObject.Properties[$field]) { $parts.Add([string]$row.$field) }
                }
                $parts -join ' | '
            }
        }
        if ($payload.Contains('diagnosticsAvailable') -and -not $payload.diagnosticsAvailable) { 'No matching compiler diagnostics retained; this does not establish zero warnings/errors.' }
        foreach ($field in @('project','seconds','total','passed','failed','skipped','log','logAvailable')) {
            if ($payload.Contains($field)) { "$field=$($payload[$field])" }
        }
        if ($payload.Contains('reports')) { foreach ($report in $payload.reports) { "report=$report" } }
    }
    return $exitCode
}

$script:requestedMode = $PSBoundParameters.ContainsKey('Mode')
try {
    $actions = [int]$Install.IsPresent + [int]$Uninstall.IsPresent + [int]$Build.IsPresent + [int]$Run.IsPresent + [int]$Clean.IsPresent + [int]$LastRun.IsPresent + [int][bool]$RunId
    if ($actions -gt 1) { Stop-InvalidArguments 'Choose only one action: Install, Uninstall, Build, Run, Clean, LastRun or RunId.' }
    if ($Help) { Show-Help; exit 0 }
    Assert-ArgumentRange 'Top' $Top 1 100
    Assert-ArgumentRange 'MaxChars' $MaxChars 32 4096
    Assert-ArgumentRange 'StackLines' $StackLines 0 20
    if ($LastRun -or $RunId) {
        $result = @(Read-JournalRun)
        $exitCode = [int]$result[$result.Count - 1]
        for ($i = 0; $i -lt $result.Count - 1; $i++) { $result[$i] }
        exit $exitCode
    }
    if ($HeartbeatSeconds -and -not ($Build -or $Run)) { throw 'invalid_arguments' }
    if ($Clean) {
        $cleaned = Clear-DotcheckReports
        if ($Json) { $cleaned | ConvertTo-Json -Compress }
        else { "CLEAN deleted=$($cleaned.deleted) skipped=$($cleaned.skipped) keep=$KeepReports" }
        if ($cleaned.skipped) { exit 1 }
        exit 0
    }
    if ($Build -or $Run) {
        $result = @(Invoke-DotcheckDotnet)
        # Output and exit travel separately; never replace a native failure with reporter success.
        if ($result.Count -lt 1) { throw 'processing_error' }
        $exitCode = [int]$result[$result.Count - 1]
        for ($i = 0; $i -lt $result.Count - 1; $i++) { $result[$i] }
        exit $exitCode
    }
    if ($Install -or $Uninstall) {
        if ($Path.Count -or $Test -or $script:requestedMode) { throw 'invalid_arguments' }
        $action = 'Install'
        if ($Uninstall) { $action = 'Uninstall' }
        $result = Update-DotcheckPath -Action $action -ToolFile $PSCommandPath
        if ($Json) { $result | ConvertTo-Json -Compress }
        else { "$($result.status.ToUpperInvariant()) path=$($result.path) changed=$($result.changed) restartShell=$($result.restartShell)" }
        exit 0
    }
    if (-not $Path.Count) { Stop-InvalidArguments 'Report reading requires -Path.' }
    if ($Mode -notin @('Summary', 'Failed', 'Skipped', 'Slow', 'Detail', 'RunErrors')) {
        Stop-InvalidArguments 'Reader -Mode must be Summary, Failed, Skipped, Slow, Detail or RunErrors.'
    }
    Assert-ArgumentRange 'MaxFiles' $MaxFiles 1 10000
    Assert-ArgumentRange 'MaxFileMiB' $MaxFileMiB 1 1024
    if ($Mode -eq 'Detail' -and -not $Test) { Stop-InvalidArguments '-Mode Detail requires -Test.' }
    if ($Mode -in @('Summary', 'RunErrors') -and $Test) { Stop-InvalidArguments '-Test cannot be combined with -Mode Summary or RunErrors.' }
    if ($Mode -ne 'Detail' -and $StackLines -gt 0) { Stop-InvalidArguments '-StackLines requires -Mode Detail.' }
    $script:files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $pathComparer = [StringComparer]::OrdinalIgnoreCase
    if ([System.IO.Path]::DirectorySeparatorChar -eq '/') { $pathComparer = [StringComparer]::Ordinal }
    $script:seen = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
    foreach ($entry in $Path) {
        try {
            $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
            $accepted = 0
            if ($item -is [System.IO.DirectoryInfo]) {
                $candidateCount = 0
                Get-ChildItem -LiteralPath $item.FullName -Filter '*.trx' -File -Recurse:$Recurse -ErrorAction Stop | ForEach-Object {
                    $candidateCount++
                    if (Add-ReportFile $_) { $accepted++ }
                }
                if ($candidateCount -eq 0) { Add-InputError $item.Name 'no_reports'; continue }
            } elseif ($item -is [System.IO.FileInfo] -and $item.Extension -eq '.trx') {
                if (Add-ReportFile $item) { $accepted++ }
            } else { Add-InputError $item.Name 'not_trx_path'; continue }
            if ($accepted -eq 0) { Add-InputError $item.Name 'no_fresh_reports' }
        } catch {
            if ($_.Exception.Message -eq 'too_many_reports') { throw }
            Add-InputError ([System.IO.Path]::GetFileName($entry)) 'path_unavailable'
        }
    }
    foreach ($file in @($files | Sort-Object -Property FullName)) {
        $script:reports.Add((Read-Report $file))
    }
    if ($files.Count -eq 0 -and $script:inputErrorCount -eq 0) { Add-InputError '' 'no_reports' }
    if ($Mode -eq 'Detail' -and $script:matched -eq 0 -and $script:inputErrorCount -eq 0) {
        Add-InputError '' 'test_not_found'
    }
    $invalid = $script:inputErrorCount
    $totals = [ordered]@{ total = 0L; passed = 0L; failed = 0L; skipped = 0L; other = 0L; runErrors = 0L }
    $seconds = 0.0
    $hasSeconds = $false
    foreach ($report in $script:reports) {
        foreach ($key in $totals.Keys.Clone()) { $totals[$key] += $report.$key }
        if ($null -ne $report.seconds) { $seconds += $report.seconds; $hasSeconds = $true }
    }
    $status = 'pass'
    $exitCode = 0
    if ($totals.failed -gt 0 -or $totals.other -gt 0 -or @($script:reports | Where-Object badRun).Count -gt 0 -or
        ($FailOnSkipped -and $totals.skipped -gt 0)) { $status = 'fail'; $exitCode = 1 }
    if ($invalid -gt 0) { $status = 'invalid'; $exitCode = 2 }
    $payload = [ordered]@{ status = $status; reports = $script:reports.Count }
    if ($Mode -eq 'Summary') {
        foreach ($key in $totals.Keys) { $payload[$key] = $totals[$key] }
        if ($hasSeconds) { $payload.sumReportSeconds = [Math]::Round($seconds, 3) }
    } else {
        if ($Mode -eq 'Slow') {
            $sorted = @($script:rows | Sort-Object -Property seconds -Descending)
            $script:rows.Clear()
            foreach ($row in $sorted) {
                $row.seconds = [Math]::Round($row.seconds, 3)
                $script:rows.Add($row)
            }
        }
        $payload.matched = $script:matched
        $payload.omitted = $script:matched - $script:rows.Count
        $payload.items = @($script:rows.ToArray())
        if ($script:unranked -gt 0) { $payload.unranked = $script:unranked }
    }
    if ($invalid -gt 0) {
        $payload.invalid = $invalid
        $payload.errors = @($script:inputErrors.ToArray())
    }
    Emit $payload
    exit $exitCode
} catch {
    $code = 'processing_error'
    if ($_.Exception.Message -in @('invalid_arguments', 'too_many_reports', 'path_install_failed',
            'path_rollback_failed', 'command_shadowed', 'path_action_windows_only','managed_argument_override',
            'runner_requires_powershell_7','unsafe_run_store','invalid_journal','unsupported_journal_schema',
            'journal_run_not_found','journal_run_has_no_reports','journal_busy')) { $code = $_.Exception.Message }
    if ($Json) {
        $errorPayload = [ordered]@{ status = 'invalid'; error = $code }
        if ($code -eq 'invalid_arguments' -and $null -ne $script:argumentDiagnostic) {
            $errorPayload.diagnostic = $script:argumentDiagnostic
        }
        $errorPayload | ConvertTo-Json -Depth 4 -Compress
    }
    else {
        "INVALID $code"
        if ($code -eq 'invalid_arguments' -and $null -ne $script:argumentDiagnostic) {
            "Detail: $($script:argumentDiagnostic.message)"
        }
        if ($code -eq 'invalid_arguments') { 'Help: dotcheck -Help [-Run|-Build|-Clean|-Mode <report-mode>]' }
    }
    exit 2
}
