# Using dotcheck

dotcheck turns .NET build/test output and TRX reports into a result you can act on.
It is useful when you need a quick answer, a focused diagnostic, or a result that
a script can process without parsing a console transcript.

Examples use PowerShell and an installed `dotcheck` command. You can also invoke
the executable by its full path; see [installation](installation.md). Run build
and test commands from the project checkout so the intended `global.json` and
SDK selection apply. Replace example project paths and test names with your own.

## What it adds to a development workflow

| Need | Mechanism | Practical benefit |
|---|---|---|
| Decide what to fix after a build | Summary and bounded compiler diagnostics | Read the relevant output before opening the full log |
| Investigate failing tests | Failed and Detail views of saved TRX | Ask follow-up questions without executing the tests again |
| Automate a check | Structured JSON and explicit exit codes | Consume a defined result rather than infer success from a log message |
| Detect incomplete evidence | TRX validation, freshness checks, and run-level errors | Missing or inconsistent reports cannot silently become a successful gate |
| Work with a coding agent | Bounded rows, text, and optional stack lines | Keep routine output from crowding code and task instructions out of context |
| Interrupt a long run | Timeouts and Windows process ownership | Stop owned descendants and avoid waiting indefinitely for inherited output pipes |
| Share build outputs | Immediate worktree lock refusal | Avoid overlapping dotcheck runs writing to the same outputs |
| Keep a record of a check | Journal entries with a reason and run ID | Find a particular run and inspect the evidence that remains available |

dotcheck uses the project's SDK and test tooling. It does not replace the compiler,
test framework, debugger, or CI system, and it does not make compilation faster.
The self-contained executable needs no separately installed .NET runtime or
PowerShell; building and testing projects still requires an appropriate SDK.

## Everyday development

Build when the question is whether the project compiles:

```powershell
dotcheck -Build -Project .\src\App\App.csproj -Configuration Release
```

Run tests when the question is whether behavior still works:

```powershell
dotcheck -Run -Project .\tests\App.Tests\App.Tests.csproj -Configuration Release
```

`dotnet test` normally builds as part of the run, so a separate preceding build
is usually unnecessary. After a small change, select the relevant tests:

```powershell
dotcheck -Run -Project .\tests\App.Tests\App.Tests.csproj -Filter 'FullyQualifiedName~OrderTests'
```

`-Filter` changes which tests execute. A passing filtered run covers that selection,
not the entire suite. `-Test` instead selects rows when inspecting diagnostics;
it does not select tests to execute or turn an unhealthy report into a pass.

Use `-NoBuild` or `-NoRestore` only when existing outputs and dependencies match
the sources, configuration, and target framework. dotcheck does not establish
that match. For multi-target projects, use `-Framework` to select the intended TFM.

## Investigate once, read several ways

Keep the TRX path from the run and start with a short failure list:

```powershell
dotcheck -Path .\TestResults\current.trx -Mode Failed -Top 5 -MaxChars 200
dotcheck -Path .\TestResults\current.trx -Mode Detail -Test Namespace.FailingTest -Top 1 -MaxChars 800 -StackLines 3
```

The second command reads the same report and includes failure details and selected
stack lines. `-Test` is a case-insensitive literal substring, so choose a specific
name if several tests match. Neither command rebuilds or reruns tests.

Other views answer different questions:

```powershell
dotcheck -Path .\TestResults\current.trx -Mode RunErrors
dotcheck -Path .\TestResults\current.trx -Mode Skipped
dotcheck -Path .\TestResults\current.trx -Mode Slow -Top 10
```

RunErrors helps investigate test-host or run-level failures. Skipped shows tests
that did not execute. Slow ranks reported test durations; it is a starting point
for investigation, not a profiler or a reliable benchmark. Summed durations are
not wall-clock time when tests run in parallel.

Prefer exact report paths. Reading a directory combines matching reports and may
include earlier attempts; counts are not deduplicated by test identity. Directory
recursion requires `-Recurse`. Use an ISO timestamp with an explicit offset when
checking freshness:

```powershell
dotcheck -Path .\TestResults -NotBefore '2026-10-21T10:00:00Z' -Mode Summary
```

Choose the actual start of your run. Freshness checks examine file and report
timestamps; they do not prove that the current sources produced a report.

## Keep useful context for a coding agent

Start with Summary or Failed, then request Detail only for the relevant test.
`-Top` limits selected rows, `-MaxChars` bounds individual displayed text values,
and `-StackLines` explicitly enables stack output in Detail mode. These are not
a total response-size or token budget.

When tool output is included in model context, selecting fewer diagnostics can
reduce token consumption and leave more room for code, requirements, and previous
decisions. Reusing saved reports also avoids repeating test execution and its
output solely to answer a follow-up question. Keep full evidence separately so
the agent can request more detail when needed.

This matters throughout an edit–test–fix loop, rather than just for one large log.
Repeated checks can otherwise add similar build messages, successful-test output,
and long stack traces to the conversation. Bounded results reduce that routine
output at each step. If the integration retains earlier tool results in later
model requests, the smaller transcript can also reduce subsequent input context.
Actual token accounting depends on the integration, including caching and pruning.

A practical agent workflow is:

1. Run the relevant tests after a code change and read the overall result.
2. If they fail, select a failure and request Detail from the saved TRX.
3. Read additional details from that report as needed, without repeating execution.
4. After applying a fix, run the appropriate tests again to obtain fresh evidence.

The same CLI and report views work across projects, so an agent can reuse these
instructions instead of assembling new console filters or XML parsing scripts.
This can save investigation steps as well as output tokens. It does not remove
the need to choose adequate test coverage or inspect details omitted by a summary.

The saving depends on the original output, selected options, tokenizer, and tool
integration. dotcheck does not count tokens, manage context automatically, or
guarantee a cost reduction. JSON is useful for structured processing; it is not
necessarily shorter than text. See the [complete AGENTS.md section](../README.md#complete-section-to-copy-into-agentsmd)
for reusable instructions.

## Use results in CI and scripts

Use a separate results directory for each run and preserve the exit code before
parsing or processing output. This example creates a new directory and returns
dotcheck's result to the caller:

```powershell
$runDirectory = Join-Path $PWD ('.dotcheck-runs/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop | Out-Null
$output = & dotcheck -Run -Project .\tests\App.Tests\App.Tests.csproj `
    -Configuration Release -ResultsDirectory $runDirectory -FailOnSkipped -Json
$checkExit = $LASTEXITCODE
$output | Set-Content -LiteralPath (Join-Path $runDirectory 'result.json') -Encoding utf8
if ($output) {
    $result = $output | ConvertFrom-Json
    $result | Select-Object condition, nativeExitCode, processTreeCompleted, reports
}
exit $checkExit
```

Keep `.dotcheck-runs/` out of source control. Retain or upload its contents only
according to your project's artifact and confidentiality rules. JSON is emitted
on stdout; optional heartbeats go to stderr. Runner JSON lists TRX paths in
`reports`; report-reader JSON uses `reports` for the number of reports.

Reader exits are 0 for healthy reports, 1 for unhealthy reports, and 2 for invalid
input. Build/Run preserves native nonzero exit codes. Timeout, capture/diagnostic
limits, and cancellation return 124, 125, and 130. A missing report or unconfirmed
completion must not be interpreted as a pass.

Set policy explicitly. `-FailOnSkipped` makes skipped tests fail the check.
`-MaxWarningDiagnostics 0` fails a build/run with any distinct captured compiler
warning. Warning counts deduplicate identical compiler diagnostic lines; they
are not a substitute for the project's analyzer configuration.

## Save and revisit a run

Create the journal's parent directory first. A journaled Build/Run requires a
nonempty reason:

```powershell
New-Item -ItemType Directory -Force .\private-results | Out-Null
dotcheck -Run -Project .\tests\App.Tests\App.Tests.csproj -JournalPath .\private-results\runs.jsonl -Reason 'Order validation regression'
dotcheck -LastRun -JournalPath .\private-results\runs.jsonl -Json
dotcheck -RunId '<GUID from the recorded run>' -JournalPath .\private-results\runs.jsonl -Mode Failed
```

Inspection never launches dotnet. LastRun selects the last started entry, which
may be unfinished or refused, rather than the last successful run. Use RunId when
you need a stable reference. Available TRX reports are rechecked, and recorded
failures remain failures. A recorded build success is historical evidence; it
does not verify changes made since then.

Compiler rows are retained according to the original output selection. To inspect
warning details later, select them when executing the build:

```powershell
dotcheck -Build -Project .\src\App\App.csproj -Mode Warnings -JournalPath .\private-results\runs.jsonl -Reason 'Review compiler warnings'
dotcheck -LastRun -JournalPath .\private-results\runs.jsonl -Mode Warnings
```

An unavailable diagnostic list does not mean there were no warnings. Journals are
not a replacement for the original reports or raw logs.

## Control long runs and shared outputs

```powershell
dotcheck -Run -Project .\tests\App.Tests\App.Tests.csproj -TimeoutSeconds 1200 -MaxLogMiB 64 -HeartbeatSeconds 60
```

Choose limits for the expected workload. The defaults are 600 seconds and 64 MiB
of native output capture. Exceeding a limit stops the run; it does not establish
test completion. Heartbeats report elapsed time, not measured progress.

dotcheck refuses concurrent Build/Run actions in the same worktree immediately;
it does not queue them. If separate projects share output directories, give them
the same `-LockRoot`. This lock does not coordinate independent `dotnet` commands.
Windows Job Objects manage owned descendants, including during interruption;
`processTreeCompleted=true` is the explicit confirmation that the job is empty.

## Retain evidence deliberately

Add `-LogPath <new-private-file>` to Build/Run only when full native output is
needed. The parent directory must exist and the file must be new. Displayed
diagnostics use best-effort redaction; raw logs, TRX, and journals may contain
secrets, private paths, or application data. Review them before sharing.

After processes finish, trim a results directory you own:

```powershell
dotcheck -Clean -ResultsDirectory .\owned-results -KeepReports 10
```

This keeps the newest eligible top-level TRX files, skips locked and reparse
files, and leaves logs, attachments, and directories intact. Cleanup is explicit;
`-KeepReports 0` removes all eligible reports.

The supported distribution target is Windows x64. See the
[CLI contract](compatibility.md) for limits and supported runner behavior.
dotcheck does not sandbox untrusted build/test code, detect flaky tests, or display
all TRX stdout, stderr, and attachments. Keep the native tooling available for
investigations that need those details.
