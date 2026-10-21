# Development

Use Windows x64, the SDK selected by `global.json`, and PowerShell 7 for scripts.
The installed CLI does not require PowerShell. Runtime code uses the BCL; MSTest
and Microsoft.NET.Test.Sdk belong to the synthetic NativeSmoke test project.

## Build and test

```powershell
pwsh -NoProfile -File .\scripts\verify.ps1
```

Verification builds projects sequentially, checks formatting, runs the behavioral
executable, publishes a fresh binary, and runs compatibility, differential,
process, contract, VSTest, cleanup, and cancellation tests. The main behavioral
project is a console application; `dotnet test` does not execute it.

File-symlink tests require Developer Mode or suitable privileges. A blocked local
symlink check is reported explicitly. Release verification uses
`-RequireFileSymlink` to make that check mandatory.

For Native AOT, install the Visual Studio Desktop development with C++ workload
and Windows SDK, then run:

```powershell
pwsh -NoProfile -File .\scripts\verify.ps1 -NativeAot
```

GitHub Actions runs managed and Native AOT Windows x64 jobs. Tests use synthetic
inputs and owned temporary directories; no database, IIS, or external application
is required. NativeSmoke contains an intentionally failing test and an expected
test analyzer warning; the published smoke selects its passing test.

## Focused checks

```powershell
dotnet build dotcheck.slnx -c Release -m:1 /nodeReuse:false
& .\tests\dotcheck.tests\bin\Release\net10.0\dotcheck.tests.exe tests/fixtures
pwsh -NoProfile -File .\tests\published-smoke.ps1 -Tool '<published-dotcheck.exe>'
```

Use matching outputs when passing NoBuild/NoRestore. Reuse saved TRX for diagnostic
inspection. Keep raw logs, journals, and machine-specific evidence out of commits.

For performance comparisons, `tests/review-benchmarks.ps1` accepts
`-ReferenceTool` and `-CandidateTool`. It alternates launches over identical
synthetic inputs; results describe the measured environment, not compilation
speed or a universal performance guarantee.

See [architecture.md](architecture.md), [compatibility.md](compatibility.md), and
[releasing.md](releasing.md) for implementation boundaries and distribution.
