# dotcheck

Version 1.1.2. CLI changes are additive; native exit codes and existing TRX-reader modes are preserved.

Single-file verification for 1.1.2: **59 checks passed**, exit 0, against a standalone copy containing only dotcheck.ps1. This includes timeout, orphan cleanup, forced runner termination and journal concurrency. Evidence: `%TEMP%/dotcheck-tests-978b0899ba034676a5a1389ba6a6ce3b`; standalone copy: `%TEMP%/dotcheck-standalone-42fd682d5fcc4c25946aff49e599c1df`. Previous tool/documentation backup: `%TEMP%/dotcheck-single-file-backup-7a1f31f0b33741a4b7c9bf8ea5688863`. Syntax passed, and README/catalog/current AGENTS.md copy blocks match. The existing platform/runner verification limitations below remain unchanged.

Single-file PowerShell runner: compact .NET build/test diagnostics and TRX reading. Windows Job Object code is embedded in dotcheck.ps1 and loaded only for Windows Build/Run. Copying dotcheck.ps1 is sufficient for execution; README and the regression harness are optional supporting files.
Runner requires PowerShell 7; report reading and PATH management also support 5.1.

    & "C:\tools\dotcheck.ps1" -Install
    dotcheck -Help
    dotcheck -Help -Run
    dotcheck -Build -Project app.csproj
    dotcheck -Build -Project app.csproj -Mode Warnings
    dotcheck -Run -Project tests.csproj -Filter "FullyQualifiedName~Suite" -NoRestore
    dotcheck -Run -Project tests.csproj -ResultsDirectory artifacts/tests -FailOnSkipped
    dotcheck -Run -Project tests.csproj -MaxWarningDiagnostics 0 -JournalPath artifacts/gates.jsonl -Reason 'Verify changed source'
    dotcheck -Path current.trx -Mode Failed
    dotcheck -Path current.trx -Mode Detail -Test TestName -StackLines 3
    dotcheck -Uninstall

Runs lock their project worktree (override with -LockRoot for shared outputs). The lock is released only after owned-tree shutdown. On Windows, Job Objects stop descendants even if the runner process is terminated. `processTreeCompleted=null` on other platforms means tree completion is unverified; false fails the run.

JSON/summary `outcome`: passed, build_failed, tests_failed, test_run_failed, aborted, timeout, report_invalid, diagnostics_exceeded or runner_failed. `test_run_failed` identifies TRX run-level errors (including a host error even when individual tests passed); it does not infer a particular crash cause from arbitrary console text. Native failures remain nonzero; missing reports cannot turn a failed compiler run into success. Warning thresholds are opt-in (-1 default). JSONL records reason, managed invocation fields, counters, diagnostics and evidence paths; raw custom argument values are deliberately omitted. Journal write failure fails the run. Report-only -Path remains unchanged.

Each journal invocation writes `started` before native startup and `finished` after reporting. New records include `schemaVersion=1`, `toolVersion`, and a shared GUID `runId`; `finished` also includes `finishedUtc`. Started records include configuration, framework, runner, verb, noBuild/noRestore, timeout and custom argument count. An unmatched start has no confirmed result and must not be counted as success; it does not prove whether a process is still running. Old unversioned journals are matched by normalized startedUtc. Journals are private evidence, not a tamper-proof audit or source/output fingerprint.

The started record is written before worktree-lock acquisition, so refused attempts have a readable failed pair. Finished is written only after successful started persistence. A missing/unwritable journal parent cannot create an orphan finish. Journal reads and appends coordinate through a separate named mutex (bounded 5-second acquisition); reads take a size-bounded text snapshot and release the lock before JSON parsing/report inspection. Two cooperating worktrees can share the same canonical journal path without interleaving writes. The lock does not protect against unrelated editors, aliases to the same file, or malicious modifications.

## Inspect a saved run without rerunning it

```powershell
dotcheck -LastRun -JournalPath private.jsonl
dotcheck -LastRun -JournalPath private.jsonl -Json
dotcheck -RunId '<GUID>' -JournalPath private.jsonl -Mode RunErrors
dotcheck -RunId '<GUID>' -JournalPath private.jsonl -Mode Detail -Test TestName
dotcheck -RunId '<GUID>' -JournalPath private.jsonl -Mode Errors
```

`LastRun` selects the last **started** entry in journal order, including an unfinished run. `RunId` selects a GUID; an old journal can be selected by its original ISO startedUtc. Neither action launches dotnet. The reader rejects malformed records, duplicate identities, unknown schema versions, invalid numeric/boolean result metadata, and unmatched finished entries; it fails instead of silently skipping damaged evidence. One explicit compatibility exception handles the known 1.1.0/unversioned orphan with exit=2, runner_failed, build_outputs_busy and no process-tree result: it remains failed and reports `startEventMissing=true`. It never becomes a successful synthetic run. Limits: MaxLogMiB (default 64) for the entire snapshot and 10000 runs. There is no arbitrary per-line limit below the total limit: supported verbose diagnostic records must remain readable. A busy snapshot returns `journal_busy` instead of waiting indefinitely.

`recordedExit` is historical evidence. Available TRX is reread through existing reader modes with freshness checked against the recorded start. The overall exit cannot become successful if either the recorded run or the current report inspection failed. `-FailOnSkipped` applies to the reread. Missing reports fail verification; a saved PASS alone does not prove current report availability. Journal inspection never reruns tests. A build has no TRX: Summary shows its recorded result with `reportVerification=not_applicable`, not a newly verified build. Detail/Failed/RunErrors require saved reports. Logs are only checked for existence and never dumped by journal inspection.

Failed Summary includes bounded retained compiler diagnostics or runner-tail diagnostics. Errors/Warnings inspect retained compiler rows, sanitized again with Top/MaxChars limits. If the original run did not retain the requested rows, `diagnosticsAvailable=false` means unavailable evidence, not zero errors/warnings. New compiler rows carry severity; old rows are inferred only when unambiguous. Mixed legacy warning/error rows without severity remain unknown and are available in failed Summary, rather than being falsely labelled. These modes still verify available TRX health through Summary and never clear the recorded failure exit. Use Mode Warnings during the original run when warning details are required later.

JSON distinguishes `reportVerification=checked`, `failed`, `unavailable`, `not_attempted` (unfinished), and `not_applicable` (build). A missing optional log does not invalidate a readable TRX, but logAvailable is false. Historical reader paths need their original evidence files; copied journals do not relocate paths automatically. See `dotcheck -LastRun -Help`.

## Optional heartbeat

Use `-HeartbeatSeconds 60` only with Build/Run when long-run visibility is useful. Default 0 disables it. Elapsed-time lines go directly to stderr, keeping stdout JSON and saved native logs unchanged. They do not report percentage, phase, actual test progress or success. The surrounding host must stream stderr for live visibility; a buffering host may show it only at completion.

## Regression checks

Run `& C:\tools\dotcheck.tests.ps1` using PowerShell 7 on Windows with an installed .NET SDK. The harness needs no SQL, application host, Pester, or external test packages. It builds one small owned native simulator and checks readers, journals, runner classification, heartbeat, timeout, orphan cleanup, abrupt runner termination, combined competing-run refusal/journal inspection, and concurrent journal writers/readers. Evidence remains in a unique temporary directory printed on success; remove only that owned directory after processes have stopped and retention permits it. `-Tool <old-script> -BaselineOnly` checks unchanged reader behavior against an older version. MTP, Unix process-tree completion, install/uninstall PATH changes and the complete Windows PowerShell 5.1 matrix are not covered by this harness. A separate 5.1 smoke check of LastRun/TRX reading passed; Build/Run still require PowerShell 7.

Verification on 12 October 2026: final harness **34 checks passed**, exit 0; unchanged reader baseline **10 checks passed** against the saved pre-change script. Final evidence: `%TEMP%/dotcheck-tests-068fc42be20d4d88b5b5b99cfafe71c9`; baseline evidence: `%TEMP%/dotcheck-tests-0957e2ed9a6a4eab922af6d8bea7af67`. Existing LEON journals/TRX were read without executing application tests: 203/203 success and a failed six-test host run both retained their correct overall health. PowerShell syntax and whitespace checks passed. The simulator validates runner orchestration, not a real VSTest host crash or actual MTP integration. Backups of the previous script/README: `%TEMP%/dotcheck-upgrade-8bc8afee4ef94d939ab954a5448a7a4e`. All temporary directories belong to this verification and are intentionally retained as evidence.

Post-review verification for **1.1.1**, 12 October 2026: **59 checks passed**, exit 0. Final evidence: `%TEMP%/dotcheck-tests-0d8789385ab349849979bc8ea98dc594`. Fixes cover orphan finished events after early refusal, retained compiler diagnostics, coordinated snapshot/appends, strict result metadata, signed native failure exits, valid large journal records, and non-guessing of ambiguous legacy severity. The harness now exercises two independent writers with concurrent inspection and forced termination of the runner alone; Windows Job Objects cleaned its child and the remaining journal start stayed unconfirmed. Separate Windows PowerShell 5.1 inspection of the existing 203-test report returned 0; the real 1.1.0 refused-run journal is readable but retains exit 2/startEventMissing. Source syntax and whitespace checks passed. No LEON build/tests, shared SQL, IIS, PATH install/uninstall, or MTP run was performed for this fix. The previous 34-check result above is historical, not the final gate for 1.1.1.

## Future .NET distribution through WinGet

This is a publishing outline, not an implemented release pipeline. For a future .NET CLI, a self-contained Windows executable is a practical portable package; produce separate supported architecture artifacts and keep the SDK requirement for building projects distinct from dotcheck's own runtime requirement. Alternatively use a silent installer. WinGet does not publish a NuGet dotnet-tool package directly as a portable executable.

1. Select a publisher/package ID (for example `YourPublisher.Dotcheck`), version, license, support URL and release repository. Check namespace availability before choosing the final ID.
2. Publish immutable versioned binaries at a public HTTPS release URL controlled by the publisher, for example GitHub Releases. Do not replace an existing version's artifact. WinGet stores manifests pointing to downloads, not the application binary itself.
3. Create manifests with installer URL, SHA-256, architecture, version, metadata, and portable command alias `dotcheck` (or installer-specific silent switches). Use the schema current at submission time and test install/upgrade/uninstall plus conflicts with the existing PowerShell command.
4. Run `winget validate <manifest-folder>` and test the local manifest in a clean Windows Sandbox. Local-manifest installation may require enabling the LocalManifestFiles setting; do not change a user's settings automatically. Include tests from a fresh shell to verify PATH/alias resolution.
5. Submit the manifests in a pull request to `microsoft/winget-pkgs`; complete automated validation and any requested review. Repeat with a new version and matching hash for each release. Approval is not guaranteed.

Official Microsoft references: [package manifests](https://learn.microsoft.com/en-us/windows/package-manager/package/manifest), [submission and validation](https://learn.microsoft.com/en-us/windows/package-manager/package/repository), [portable manifest fields](https://github.com/microsoft/winget-pkgs/blob/master/doc/manifest/schema/1.28.0/installer.md). Do not assume code signing is mandatory for every portable executable: requirements depend on package type/policy. Verify current requirements when publishing; signing can still improve provenance and deployment experience.

Install derives PATH from the executing file's CURRENT directory. Repeat after moving
the file; old owned User/process PATH registrations are repaired. DOTCHECK_TOOL_FILE
remembers the location; installation also removes the legacy TRX_TOOL_FILE marker.
Uninstall removes owned registrations, not files. Foreign aliases and Machine PATH
are unchanged. Call with & in the current PowerShell; existing terminals may need
restarting. Command dotcheck is for PowerShell, not cmd.exe.

## Runner

For ordinary successful builds, native dotnet build -v:q is already economical.
Use -Build when bounded compiler diagnostics save log processing. Use -Run for compact
test results; if a native command already gave the needed summary, keep that result.
For questions about existing TRX, use -Path instead of running tests again. This tool
reduces output/orchestration; it does not promise faster compilation or test execution.

Summary returns one line on success; failure includes bounded compiler/test diagnostics.
Build modes: Summary, Errors, Warnings. Test modes additionally include Failed, Skipped,
Slow, Detail -Test <literal substring>, RunErrors. Default Summary includes failing test
messages; Failed lists names. Use -Json only for processing.

-Project defaults to the current directory; -Configuration Debug; optional -Framework.
-NoRestore/-NoBuild only when valid; dotnet test performs its own build by default.
-DotnetArgs accepts an array of extra native arguments without shell evaluation;
managed options (project, logger, results, filter, configuration) cannot be overridden.
-Filter selects tests; -Test filters report diagnostics and does not change overall health.
-Runner Auto reads the nearest ancestor global.json; explicit VSTest/MTP is available.
Native MTP requires its TRX extension and extension support for forwarded --filter.
For MTP, specify -ResultsDirectory for predictable discovery; native MTP integration
has not been runtime-verified. No experimental report merging is used.
See [MTP reports](https://learn.microsoft.com/en-us/dotnet/core/testing/microsoft-testing-platform-test-reports)
and [dotnet test MTP](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-test-mtp).

Reports stay where native dotnet test writes them. -ResultsDirectory passes through the
native option; relative paths resolve from the caller's current directory. Without it,
the native default remains (VSTest: the test project's TestResults). No global report
folder, run subdirectories, metadata files, or automatic deletion are created.
Only reports reported by this invocation are read; directory fallback checks freshness.
Avoid concurrent invocations sharing a results directory, especially with fixed filenames.
-LogPath <file> optionally retains full stdout/stderr; it must be a NEW file in an existing
directory. Without it, no console log is persisted. Full logs may contain sensitive data;
compact displayed diagnostics use best-effort redaction.

Old reports accumulate according to the native logger's naming/overwrite policy.
Cleanup is EXPLICIT and only affects top-level *.trx in the specified directory:

    dotcheck -Clean -ResultsDirectory artifacts/tests -KeepReports 10

Run cleanup after tests stop. It retains the newest 10 report files (not test runs),
skips locked files and reparse points, and never deletes directories, logs or attachments.
-KeepReports 0 deletes all eligible top-level TRX. No cleanup is performed on build/test.

Native nonzero exit is preserved. Native success with missing/empty/invalid TRX returns 2;
test/run failures or -FailOnSkipped return 1. Timeout returns 124; captured log-size limit
returns 125. Defaults: -TimeoutSeconds 600, -MaxLogMiB 64, -Top 5, -MaxChars 350.
Limits bound emitted output and aggregate captured bytes; they are not a sandbox.

Invalid numeric arguments report the parameter, rejected value and inclusive range,
while keeping exit 2 and the `invalid_arguments` code. For example, `-MaxChars 4500`
reports `MaxChars=4500 must be between 32 and 4096 (inclusive).` The default remains 350.
With `-Json`, existing `status`/`error` fields are preserved and an optional
`diagnostic` object adds `message`, `argument`, `value`, `minimum` and `maximum`.
Selected invalid option combinations also include a corrective message; user-supplied
paths, test/filter text and unknown string values are not echoed in these diagnostics.

## Report reader

-Path accepts literal files, arrays, or a directory; -Recurse is opt-in. Prefer exact
current-run files. -NotBefore <run-start> checks file and report timestamps.
Summary, Failed, Skipped, Slow, Detail and RunErrors remain available; -Test is a
case-insensitive literal substring. Stack is opt-in with Detail, default 0 lines.
Reader exit 0/1/2 means healthy/failure/invalid; preserve the separate test-process exit.
TRX stdout/stderr are never shown. Empty reports and hierarchical InnerResults fail
closed; DTD/external entities are disabled. Aggregate counts include separate attempts;
summed report duration is not parallel elapsed time.

## Copy into AGENTS.md

The complete reusable block below is the source for repository guidance. Copy it as one section, replacing the existing dotcheck section instead of appending another one. Keep all dotcheck-specific instructions in that section; remove duplicate tool descriptions from other sections. Adjust only the installation path if necessary. Keep this block current when the CLI or usage contract changes. Repository-specific gates belong to the task's verification instructions.

```markdown
### dotcheck

- Use `dotcheck -Build -Project <project>` when bounded compiler diagnostics save log processing; it does not accelerate compilation.
- Use `dotcheck -Run -Project <tests.csproj> [-Filter <expression>]` for compact test execution; do not add a separate build before it.
- Reuse sufficient native results; do not repeat a command merely to reformat its output.
- Use `-NoBuild` / `-NoRestore` only when outputs / restored dependencies match current sources and configuration; dotcheck does not establish that match.
- Use `-FailOnSkipped` for mandatory gates and `-MaxWarningDiagnostics 0` only when zero compiler warnings are required.
- Read saved TRX with `dotcheck -Path <current-run.trx>` instead of rerunning tests or writing a custom TRX parser.
- Use `-Mode Failed` for names, `Detail -Test <literal-substring>` for selected diagnostics, and `Skipped`, `Slow`, or `RunErrors` for those specific questions.
- Bound output with `-Top` and `-MaxChars`; `-StackLines` is opt-in for Detail, and `-Json` is for structured processing.
- Use `-NotBefore <run-start>` to reject stale reports; diagnostic filters do not change overall report health.
- Preserve exit codes; missing, empty, invalid reports and unconfirmed runs must not count as success.
- Use `-JournalPath <private-jsonl> -Reason <concrete-reason>` for execution evidence; new records carry a runId.
- Inspect saved runs with `dotcheck -LastRun -JournalPath <private-jsonl>` or `-RunId <id>`; these actions never start dotnet, and LastRun may select an unfinished run.
- Journal inspection rechecks available TRX; recorded build success is historical evidence, not a fresh build or a source/output fingerprint.
- Use journal `-Mode Errors` / `Warnings` for retained compiler diagnostics; missing retained rows do not establish zero diagnostics, and recorded failures remain failures.
- Use `-HeartbeatSeconds 60` only when long-run visibility helps; stderr heartbeats show elapsed time, not actual progress or completion.
- The worktree mutex refuses competing dotcheck runs immediately; it neither queues them nor blocks independent native dotnet commands.
- `-ResultsDirectory` preserves native path semantics; there is no automatic cleanup. Clean only owned evidence explicitly after processes stop.
- Use `-LogPath <new-private-file>` only when full console evidence is needed; raw logs may contain secrets despite redacted displayed diagnostics.
- Build/Run require PowerShell 7; use `dotcheck -Help -Run` or `dotcheck -LastRun -Help` for targeted help.
- If PATH is stale, invoke `& "C:\tools\dotcheck.ps1"` directly; `-Install` repairs registration using the current script location. Runtime distribution requires only dotcheck.ps1; Windows process-tree support is embedded.
- `-Filter` selects executed tests; `-Test` is a case-insensitive literal substring selecting report diagnostics only. Diagnostic selection does not change overall report health.
- Match `-Configuration` and `-Framework` to the intended gate; configuration defaults to Debug. Pass extra native options as a `-DotnetArgs` array, not a shell command; managed options cannot be overridden.
- Set `-LockRoot` when different projects/worktrees share build outputs; the default worktree lock does not coordinate arbitrary shared output paths.
- Choose `-TimeoutSeconds` and `-MaxLogMiB` for the gate; defaults are 600 seconds and 64 MiB. Timeout exits 124 and captured-log limit exits 125; neither proves completion.
- Use separate results directories for independent runs. Relative `-ResultsDirectory` paths resolve from the caller's current directory; fixed report filenames may overwrite evidence.
- `-Runner Auto` reads the nearest ancestor global.json. Native MTP needs the TRX extension and support for forwarded filters; use an explicit results directory and do not claim runtime verification from simulator coverage.
- `-Path` accepts exact files, arrays, or a directory; recursion is opt-in. Prefer exact current-run files. Summed report durations are not parallel wall-clock duration.
- Optional `-Clean -ResultsDirectory <owned-directory> -KeepReports <count>` removes only eligible top-level TRX after processes stop; it does not remove logs, attachments, or directories. Zero retains no eligible reports.
```
