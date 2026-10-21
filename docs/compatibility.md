# dotcheck 1.0.0 compatibility contract

The baseline is captured PowerShell 1.1.2 source, SHA-256
`E0795C30A9E5F408911E20ABAEC2A1F9392D04640AD6B66E8C194AD4CD9AB7F1`.
Reference hashes are in `reference/manifest.json`. Its README is historical;
the tables below describe the .NET implementation. Verification commands are in
[development.md](development.md).

## CLI and output

Arguments use case-insensitive PowerShell-style names. Actions, defaults, ranges,
JSON field types, reader decisions, native exit codes, and legacy journals are
preserved except for the deliberate fixes below. JSON uses stdout; heartbeats
report elapsed time on stderr. Diagnostic selection does not change the result.
Optional raw logs may contain secrets.

Reader exits are 0/1/2 for healthy/failure/invalid. Missing or invalid reports,
aborted runs, and run-level errors cannot establish success. Timeout,
output/diagnostic limits, and cancellation return 124/125/130.

## Reader

The XML reader rejects DTDs/external entities, unsupported hierarchical results,
inconsistent counters, and reports outside size/count limits. `-NotBefore` checks
file and report freshness. TRX stdout/stderr are not displayed. Aggregated counts
include separate attempts; summed durations are not wall time.

## Native execution

Native arguments use `ProcessStartInfo.ArgumentList`, without shell interpolation.
VSTest is the verified runner. MTP forwarding requires separate runtime
verification. Relative results paths resolve from the caller's current directory.
The worktree mutex refuses competing dotcheck runs immediately; independent
native dotnet commands are outside that lock.

Windows jobs own native descendants. Timeout, cancellation, parent death, and
capture limits trigger owned-process shutdown with bounded pipe draining.
`processTreeCompleted=true` requires confirmation; false and null are distinct.

## Journals

New records use schemaVersion=1 and GUID runId; supported legacy timestamps remain
readable. Started is persisted before native startup/lock refusal, finished after
reporting. Failed persistence fails the action. Reads and writes share a separate
bounded mutex and size-limited snapshot protocol.

`LastRun` selects the last started entry, including unfinished runs. Inspection
never launches dotnet, repairs a journal, or clears a recorded failure. Available
TRX is rechecked; recorded build success does not verify current sources.
Malformed/duplicate records and inconsistent metadata are rejected, subject only
to the specific historical orphan exception implemented in Journal.cs.

## Cleanup and installation

Cleanup removes eligible top-level TRX only, after native processes stop. Locked
files and reparse paths are protected. `KeepReports=0` removes all eligible reports;
logs, attachments, and directories remain untouched.

Manual Install/Uninstall modifies owned registration without copying executables
or deleting files. WinGet uses separate package-manager ownership; see
[winget.md](winget.md).

## Complete CLI inventory

Names are case-insensitive. PowerShell-style `-Name` is preserved, with `--Name`
also accepted. Aliases: `p`, `h`, `?`. Native argv does not run PowerShell's
parameter binder: arrays use separate tokens or repeated Path/DotnetArgs, while
`a,b` is a literal filename. With no action, the CLI reads Path. Help supports
an action context. Active Build/Run/Clean/Install/Uninstall/LastRun/RunId actions
are mutually exclusive.

Switch values: absent=false, `-Json`=true, `-Json:true`, `-Json:false`; PowerShell
may also pass `'-Json:$true'`/`'-Json:$false'` as literal argv. Do not pass a switch
value as a separate token. Unknown names and invalid modes return exit 2.

| Parameter | Default / range / purpose |
|---|---|
| Path (p) | []; literal files/directory/array |
| Mode | Summary; Failed, Skipped, Slow, Detail, RunErrors; runner/journal also support Errors and Warnings |
| Test | ''; case-insensitive literal substring; required with Detail; forbidden with Summary/RunErrors/Errors/Warnings |
| Top | 5; 1..100 |
| MaxChars | 350; 32..4096 |
| StackLines | 0; 0..20, Detail only |
| Json, Recurse, FailOnSkipped | false |
| Help (h, ?) | false |
| Install, Uninstall, Build, Run, Clean, LastRun | false |
| Project | .; file or directory; Build/Run |
| Configuration | Debug |
| Framework, Filter | ''; Filter selects executed tests |
| Runner | Auto; Auto/VSTest/MTP, case-insensitive |
| NoRestore, NoBuild | false; Build forbids NoBuild |
| DotnetArgs | []; managed arguments are forbidden; arrays end at the next known option |
| TimeoutSeconds | 600; 1..86400 |
| ResultsDirectory, LogPath, JournalPath | ''; relative to CWD; journal parent must exist |
| RunId | ''; GUID or legacy ISO startedUtc |
| HeartbeatSeconds | 0; 0..86400; Build/Run only |
| Reason | ''; nonempty for journal execution; displayed text is bounded/redacted |
| LockRoot | ''; nearest .git ancestor of the project, otherwise the project directory |
| MaxWarningDiagnostics | -1; -1..2147483647; -1 disables the threshold |
| KeepReports | 10; 0..10000 |
| MaxLogMiB | 64; 1..1024; total native capture / journal snapshot |
| NotBefore | null; ISO/offset preferred, invariant culture first then current culture; local timezone if omitted; comparisons in UTC |
| MaxFiles | 100; 1..10000 |
| MaxFileMiB | 128; 1..1024 |

Scalar parameters cannot be repeated. The native executable accepts exact names,
not PowerShell unique-prefix binding or common parameters such as Verbose.
This is an explicit shell-migration boundary; functional source parameters are
preserved. Ranges are checked before inputs are processed. Arrays and booleans
are passed as argv without shell evaluation. There is no PowerShell wrapper.

`Runner Auto` reads the nearest global.json from caller CWD, matching the captured
source. MTP receives --project/--solution and -- --report-trx; actual runner and
TRX extension support have not been proved. Native dotnet selects the SDK;
dotcheck does not replace the user's global.json. VSTest keeps quiet, -m:1,
/nodeReuse:false, --tl:off, TRX, and console minimal loggers.

## JSON and outcomes

| Surface | Preserved fields and semantics |
|---|---|
| Reader Summary | status, reports (number), total/passed/failed/skipped/other/runErrors (numbers); optional sumReportSeconds; invalid/errors only for input failures |
| Reader listings | status, reports, matched, omitted, items[]; optional unranked; row fields report/test/outcome/seconds/message/stack/truncated depend on mode |
| Input errors | status=invalid, error; invalid_arguments may contain diagnostic with message/argument/value/minimum/maximum; user strings are not echoed |
| Runner | phase, status, exit, nativeExit, seconds, outcome, runId, processTreeCompleted (null/false/true), warningDiagnostics; optional errorDiagnostics, condition, reportErrors, items, omitted, diagnostics, log, maxWarningDiagnostics |
| Test runner | reports is an array of absolute paths; total/passed/failed/skipped/other |
| Journal inspection | runId, startedUtc, status, outcome, reportVerification, exit; recordedExit for finished runs; metadata, reports[], optional inspection/recordedDiagnostics/diagnosticsAvailable/logAvailable/startEventMissing |
| Cleanup | deleted, skipped; exit 1 if files were skipped |
| Setup | status installed/uninstalled, path, changed, restartShell |

Do not confuse the reader's numeric reports field with the reports array in
runner/inspection results. Missing optional fields do not mean zero. Unfinished
inspection uses exit 1, status unconfirmed, outcome unfinished, and verification
not_attempted. Verification values checked/failed/unavailable/not_applicable
retain their original meanings. New journal entries use schemaVersion=1,
toolVersion=1.0.0, and GUID runId; legacy timestamps remain supported. Unicode
JSON escaping may differ textually; compare JSON values and types.

Outcome precedence is preserved: timeout; compiler failure; aborted; invalid
report; runner condition; run-level failure; test failure; build failure; warning
threshold; passed. Native nonzero exits take precedence over report exits;
completion failures never improve an exit. Timeout/output limit/Ctrl+C return
124/125/130 respectively. A healthy TRX never clears an unknown native failure.
Diagnostic filters do not change these decisions.

## Deliberate fixes and mechanical adaptations

| Difference from captured source | Rationale, contract, and regression evidence |
|---|---|
| Helper handshake closes the Process.Start -> Assign race | Native dotnet starts only inside the job. Before the handshake, the worker exits on stdin EOF or after 10 s; parent death cannot leave an untracked native spawn. process-gates early/delayed/runner kill |
| Root exit is handled BEFORE full pipe draining | The captured runner could wait for inherited pipes until timeout. The new runner stops the job, checks its active count, then allows at most 2 s for drains plus 1 s cancellation. parentkill/pipes gates |
| Chunk-based capture; native lines over 8192 characters are omitted entirely | ReadLineAsync could accumulate an unbounded single line. Aggregate UTF-8 capture is bounded; flood/longline regression. An oversized line cannot expose a partially displayed credential |
| Compiler error + native exit 0 -> failure 1 | The oracle could return pass with outcome=build_failed. This confirmed fail-open defect is not mandatory compatibility. Simulator compilerzero and contract-regressions evidence |
| Managed MSBuild property/response-file bypasses are forbidden | The captured regex allowed -p:Configuration, VSTestTestCaseFilter, and response files. These override managed options or hide arguments. Regressions include property lists and @file; ordinary custom arguments remain literal |
| Contradictory saved success metadata is rejected | exit=0 with outcome!=passed or nativeExit!=0 is rejected; duplicate JSON keys are rejected. Synthetic journal regressions, without general tolerance of damaged records |
| Cleanup does not replace an earlier signed failure with 1 | On revalidation with tree=false, an earlier nonzero exit is preserved; a healthy record becomes failure. Failures cannot improve |
| Native Install/Uninstall | User/process environment transaction through an abstraction; metadata ownership, rollback, foreign markers preserved. No profiles/aliases/functions or ps1 file. Registration is tested separately from package-manager installation |
| Clean also rejects reparse ancestors | A junction/child cannot bypass target checks. Junction and file-symlink behavior is verified in Windows CI |
| Report discovery skips reparse directories | Recursive traversal does not escape the input directory tree; literal file paths remain supported |
| Distinct compiler diagnostics are capped at 65,536 | Full SHA-256 value keys replace allocated hex strings. Exceeding the cap fails closed with exit 125 and condition=diagnostic_limit, independently of MaxLogMiB; process regression verifies bounded output and completed ownership cleanup |
| Duplicate Results File announcements do not exhaust MaxFiles | The limit counts distinct paths rather than repeated announcements of the same TRX; behavioral regression with MaxFiles=1 |
| Trailing directory separators share the same worktree lock | Normalize the directory key before hashing; two-process regression verifies immediate refusal rather than concurrent output access |
| Additional contradictory journal metadata is rejected | A saved PASS cannot contain failed/other tests or compiler errors. When all five test counters exist, their sum must match total without overflow. Partial legacy metadata remains supported; focused journal regressions verify rejection and a consistent success |
| Oversized diagnostic values are omitted | Inputs longer than 32,768 characters are replaced before redaction. Source-generated redaction regexes have finite timeouts; no oversized prefix is emitted |
| JSON serialization is reflection-free | Source-generated metadata covers concrete contract value types. Optional fields, nulls, signed exits, numeric types, and Unicode values retain their JSON meanings; managed builds also disable reflection fallback |
| Help/text rendering | Mode meanings and bounded diagnostics are preserved; Help text and line formatting are adapted to the executable. JSON is the machine contract. Text listings show health; parse errors do not expose arguments |

Reader ordering was restored to culture-sensitive FullName ordering, matching
Sort-Object; the differential Unicode regression is retained. This fixes a
migration defect rather than changing the original contract.
