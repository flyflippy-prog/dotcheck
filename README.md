# dotcheck

A .NET 10 command-line tool for Windows x64 that runs builds and tests, validates
TRX reports, and presents bounded diagnostics for developers, CI, and coding agents.
The self-contained executable includes the .NET runtime. Building or testing a
project requires the SDK selected by that project.

[Usage guide](docs/usage.md) · [CLI contract](docs/compatibility.md) · [Installation](docs/installation.md) ·
[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md)

[GitHub](https://github.com/flyflippy-prog/dotcheck) ·
[Actions](https://github.com/flyflippy-prog/dotcheck/actions) ·
[Releases](https://github.com/flyflippy-prog/dotcheck/releases)

## When to use dotcheck

dotcheck helps when a build or test run leaves more output than you need to decide
what failed and what to investigate next.

| Workflow | What you get |
|---|---|
| Local development | A concise build/test result, with compiler diagnostics or selected failed-test details instead of the entire console transcript |
| Investigating a failed run | Read the existing TRX, list failures, then inspect one test without repeating the run |
| CI and scripts | JSON and exit codes for automation, with missing or inconsistent reports treated as invalid results |
| Coding agents | Bounded diagnostics and saved-run inspection, so an agent can request relevant details and reuse available results |
| Long or interrupted runs | Timeouts, bounded capture, and owned-process cleanup help automation finish predictably |
| Projects sharing build outputs | A worktree lock rejects overlapping dotcheck runs before they compete for the same outputs |

Build/Run uses the project's .NET SDK and existing test tooling. Report inspection
can also be used independently with TRX produced by another build or CI job.
Windows process ownership and timeouts help keep an interrupted run from leaving
its child processes running.

For example, after a failed test run, start with a failure list and request details
only for the test you are investigating:

```powershell
dotcheck -Path .\TestResults\current.trx -Mode Failed -Top 5 -MaxChars 200
dotcheck -Path .\TestResults\current.trx -Mode Detail -Test Namespace.FailingTest -Top 1 -MaxChars 800 -StackLines 3
```

Both commands inspect the saved report. They do not rebuild the project or execute
tests. dotcheck's benefit is a shorter path from a completed run to useful
diagnostics; build and test execution time still depends on the project and SDK.

The [usage guide](docs/usage.md) covers everyday development, failure investigation,
CI integration, saved runs, and practical limits. Use it to choose a workflow;
the [CLI contract](docs/compatibility.md) lists every option and default.

## Smaller context for coding agents

When an agent includes command output in its model context, long build logs and
repeated diagnostics consume tokens alongside the code and task instructions.
dotcheck can reduce that overhead by returning a summary or a bounded selection
of diagnostics. This leaves more context available for investigating the problem.

Start with Summary or Failed, limit rows and text with `-Top` and `-MaxChars`, then
request Detail and stack lines for the relevant test. Reuse saved TRX reports or
journals for follow-up questions instead of repeating a run and its output.
The underlying reports remain available; selecting fewer details does not change
the overall result or exit code.

dotcheck does not count tokens or enforce a model's context limit. Token savings
depend on the original output, selected options, tokenizer, and how the agent
includes tool results. A fixed token or cost reduction is not guaranteed.

## Quick start

From a source checkout, build a self-contained executable:

```powershell
dotnet publish .\src\dotcheck\dotcheck.csproj -c Release -r win-x64 --self-contained true -o .\artifacts\dev-win-x64 -m:1 /nodeReuse:false
$dc = (Resolve-Path '.\artifacts\dev-win-x64\dotcheck.exe').Path
& $dc -Help
& $dc -Build -Project .\app.csproj
& $dc -Run -Project .\tests.csproj -Filter 'FullyQualifiedName~Suite' -FailOnSkipped
& $dc -Path .\TestResults\current.trx
& $dc -Path .\TestResults\current.trx -Mode Detail -Test Namespace.Test -StackLines 3
```

The executable can be run directly; PATH registration is optional. See
[Installation](docs/installation.md) for registration and removal.
PowerShell is required only for development scripts.

## Builds, tests, and report inspection

`-Filter` selects tests to execute. `-Test` selects diagnostic rows by a
case-insensitive literal substring. `-Mode`, filters, and output limits do not
change the overall result. `dotnet test` normally builds the project itself;
use `-NoBuild` and `-NoRestore` only with matching outputs and dependencies.

Reader exit codes are 0 for healthy reports, 1 for failures, and 2 for invalid
input. Native nonzero exit codes are preserved. Timeout, output/diagnostic limit,
and cancellation return 124, 125, and 130. Missing, stale, empty, or inconsistent
reports cannot establish a successful test run.

Output is bounded by `-Top` and `-MaxChars`; `-StackLines` is available in Detail
mode. Use `-Json` for structured output. JSON is written to stdout; optional
elapsed-time heartbeats use stderr. Native capture defaults to 64 MiB and stops
at 65,536 distinct compiler diagnostics. Oversized diagnostic values are omitted
before redaction. Raw logs require `-LogPath <new-file>` and may contain secrets.

A worktree lock refuses competing dotcheck runs immediately. Use `-LockRoot` when
projects share outputs. Independent `dotnet` commands are outside this lock.
On Windows, owned descendants are managed by a Job Object;
`processTreeCompleted=true` requires confirmation that the job is empty.

Relative `-ResultsDirectory` paths resolve from the caller's current directory.
Reports are retained unless cleanup is requested explicitly:

```powershell
& $dc -Clean -ResultsDirectory .\owned-results -KeepReports 10
```

Cleanup removes eligible top-level TRX files only. It skips locked and reparse
files and leaves logs, attachments, and directories intact.

## Saved runs

```powershell
& $dc -Run -Project .\tests.csproj -JournalPath .\private.jsonl -Reason 'regression check'
& $dc -LastRun -JournalPath .\private.jsonl -Json
& $dc -RunId '<GUID>' -JournalPath .\private.jsonl -Mode Errors
```

Journal inspection never launches dotnet. `-LastRun` can select an unfinished run.
Available TRX reports are rechecked and recorded failures are preserved. A saved
build success does not verify current sources. Missing retained diagnostics mean
that diagnostics are unavailable, rather than that no diagnostics occurred.

## Development and verification

Use the SDK specified by `global.json` and PowerShell 7. Run the same checks as CI:

```powershell
pwsh -NoProfile -File .\scripts\verify.ps1
```

The script builds projects sequentially and runs the behavioral executable,
legacy compatibility, differential, process, cleanup, real VSTest, and cancellation
checks. The behavioral project is a console application; `dotnet test` does not
execute it. NativeSmoke contains an intentionally failing test for failure-path
checks; the normal published smoke selects its passing test.

Create a distributable ZIP in a new directory:

```powershell
pwsh -NoProfile -File .\scripts\package.ps1 -OutputDirectory artifacts/dotcheck-1.0.0-win-x64
```

The release workflow tests the packaged executable and creates a draft GitHub
Release. Maintainer instructions are in [the release guide](docs/releasing.md).

## Support and limitations

The distribution target is self-contained Windows x64. CI verifies managed and
Native AOT builds, including compatibility, process lifetime, report cleanup,
and cancellation. ZIP packaging uses the managed build.

To build and verify Native AOT, install the Visual Studio Desktop development
with C++ workload and Windows SDK, then run:

```powershell
pwsh -NoProfile -File .\scripts\verify.ps1 -NativeAot
```

Other operating systems, ARM64, and Microsoft.Testing.Platform integration are
unverified. dotcheck reduces diagnostic output; it does not accelerate compilation
or isolate untrusted build/test code. See the
[compatibility contract](docs/compatibility.md) for supported behavior and
[development guide](docs/development.md) for verification commands.

## License

Copyright (c) 2026 flyflippy. The project's own C#, PowerShell, tests, fixtures,
scripts, and documentation are licensed under [Apache-2.0](LICENSE). This includes
the captured PowerShell baseline without altering its bytes. [NOTICE](NOTICE)
records attribution; [Licensing](docs/licensing.md) describes the scope.

Microsoft .NET and test dependencies retain their own licenses. Self-contained
packages include `DOTNET-LICENSE.TXT` and `DOTNET-THIRD-PARTY-NOTICES.TXT` alongside
dotcheck's LICENSE and NOTICE. No separate .NET runtime installation is required.

## Complete section to copy into AGENTS.md

Copy the complete section below into the AGENTS.md of a project using dotcheck.

```markdown
### dotcheck

- Use `dotcheck -Build -Project <project>` for bounded compiler diagnostics; it does not speed up compilation.
- Use `dotcheck -Run -Project <tests.csproj> [-Filter <expression>]` for concise test execution; a separate preceding build is normally unnecessary.
- Reuse sufficient native results; do not repeat a run only to reformat its output.
- Use `-NoBuild` / `-NoRestore` only when outputs / dependencies match current sources, Configuration, and Framework; dotcheck does not establish that match.
- Use `-FailOnSkipped` for mandatory gates; set `-MaxWarningDiagnostics 0` only when zero compiler warnings are required.
- Read saved TRX with `dotcheck -Path <current-run.trx>` instead of rerunning tests or writing a custom TRX parser.
- Modes: `-Mode Failed` for names; `Detail -Test <literal-substring>` for diagnostics; `Skipped`, `Slow`, and `RunErrors` for those specific questions.
- `-Filter` selects tests to execute; `-Test` is a case-insensitive literal substring selecting diagnostic rows only. Diagnostic filters and modes never change overall health.
- Bound output with `-Top` and `-MaxChars`; enable `-StackLines` explicitly with Detail only; use `-Json` for processing.
- Use `-NotBefore <run-start>` to reject stale files/runs. Prefer exact current-run files. Path accepts separate array arguments and directories; recursion requires Recurse.
- Preserve exit codes: reader 0/1/2 = healthy/failure/invalid; native nonzero exits are preserved; missing/empty/invalid TRX and unconfirmed runs must not count as success.
- Choose `-TimeoutSeconds` and `-MaxLogMiB` for the gate; defaults are 600 seconds and 64 MiB. Timeout 124, output/diagnostic limit 125, and Ctrl+C 130 are not successful completion. More than 65,536 distinct compiler diagnostics returns condition=diagnostic_limit.
- `processTreeCompleted=true` requires Job Object confirmation; false/null do not establish completed cleanup.
- Use `-JournalPath <private-jsonl> -Reason <concrete-reason>` for execution evidence; new records carry a GUID runId.
- `dotcheck -LastRun -JournalPath <private-jsonl>` and `-RunId <id>` never launch dotnet; LastRun may select an unfinished run.
- Inspection rechecks available TRX for freshness and preserves historical failures. A recorded build PASS is historical evidence, not a fresh build or source fingerprint.
- Journal `-Mode Errors` / `Warnings` shows retained compiler rows; missing rows mean unavailable evidence, not zero errors/warnings.
- Enable `-HeartbeatSeconds 60` only for long runs; stderr heartbeats show elapsed time, not actual progress or completion.
- The worktree mutex immediately refuses competing dotcheck runs without queuing; it does not block independent native dotnet commands. Use `-LockRoot` for shared outputs.
- Configuration defaults to Debug; select Framework for the intended gate. Pass extra native options as separate `-DotnetArgs` arguments, without shell strings; managed-option and response-file overrides are forbidden.
- `-ResultsDirectory` preserves native path semantics; relative paths resolve from caller CWD. Use separate directories for independent runs; fixed filenames may overwrite evidence.
- Cleanup is never automatic. Run `-Clean -ResultsDirectory <owned-directory> -KeepReports <count>` after processes stop: only eligible top-level TRX, without logs/attachments/directories. Zero removes all eligible reports; locked/reparse files are skipped.
- Enable `-LogPath <new-private-file>` only when full raw evidence is needed: raw logs may contain secrets despite displayed diagnostic redaction.
- Summed report durations are not parallel wall-clock time; aggregate counts include separate attempts.
- `-Runner Auto` reads the nearest ancestor global.json. Actual MTP requires its TRX extension, filter support, and a separate runtime gate; simulator coverage is not proof.
- The published Windows x64 executable needs neither PowerShell nor an installed .NET runtime; Build/Run need an appropriate SDK. Do not claim ARM64/Unix/AOT/MTP verification without their gates.
- Use the verified installed command; if command resolution is uncertain, invoke its explicit executable path. Installation and PATH changes require user authorization. Open a new shell after registration.
- For manual upgrades, keep the previous executable in a separate directory. Use the installation method's removal commands; do not remove foreign commands or files.
```
