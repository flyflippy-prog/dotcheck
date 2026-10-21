# Architecture

dotcheck is a .NET 10 CLI with BCL-only runtime dependencies. The Windows x64
executable is self-contained. Build/Run delegates to the SDK selected by the user's
project; report and journal inspection do not launch dotnet.

## Responsibilities

| Component | Responsibility |
|---|---|
| Options.cs | Argument parsing, ranges, and action/mode validation |
| ReportReader.cs | Streaming TRX parsing, report health, input limits, retained rows |
| Runner.cs | Native invocation, worktree locking, result selection, journal lifecycle |
| OwnedProcess.cs | Worker handshake, Windows Job Object ownership, process shutdown |
| NativeCapture.cs | Concurrent bounded stdout/stderr capture and compiler diagnostics |
| Journal.cs | Paired records, bounded snapshots, legacy reading, report revalidation |
| Setup.cs | Explicit report cleanup and transactional manual PATH registration |
| Output.cs | Bounded rendering and diagnostic redaction |
| JsonOutputContext.cs | Source-generated JSON metadata |

Native arguments use ProcessStartInfo.ArgumentList. A worker handshake assigns
process ownership before native code starts. Parent death, timeout, cancellation,
and capture limits stop owned descendants; pipe draining has a finite bound.
Process-tree completion is reported only after Job Object confirmation.

TRX is streamed with DTDs and external entities disabled. Input size/count limits
and bounded retained rows constrain memory. Compiler diagnostics have independent
byte and cardinality limits. XML and journal inconsistencies fail the operation.

JSON, regular expressions, and Win32 interop use source generation. Reflection
fallback is disabled for JSON. Register additional concrete JSON value types in
JsonOutputContext and verify published output when extending the contract.

## Compatibility fixtures

`reference/powershell/` and `reference/manifest.json` are immutable test inputs from
the original implementation. Preserve their bytes and hashes. They are not the
production executable or current user documentation. Tests use synthetic reports,
owned temporary resources, a process simulator, and a minimal VSTest project.

See [compatibility.md](compatibility.md) for the CLI and JSON contract and
[development.md](development.md) for verification commands.
