# Working instructions

- Read docs/architecture.md, docs/development.md, and the relevant part of docs/compatibility.md before implementation.
- Keep reference/powershell/ and reference/manifest.json byte-for-byte intact. They are captured test inputs, not production files.
- Preserve CLI arguments, report-health decisions, exit codes, JSON fields, journal compatibility, path semantics, and bounded diagnostics. Test behavior.
- Windows x64 is the primary target. Managed and Native AOT have CI jobs; other platforms, ARM64, and MTP need their own runtime verification.
- Use .NET 10 and the SDK selected by global.json. Prefer BCL APIs and justify additional runtime packages. The installed CLI must not require PowerShell.
- Keep report reading, native execution, process lifetime, journals, rendering, and setup separate. Avoid generic frameworks or service architecture.
- Use ProcessStartInfo.ArgumentList, concurrent bounded stdout/stderr reads, explicit native exits, and owned-process cleanup. Never evaluate shell command strings.
- Windows process-tree termination must survive runner death. Inherited open pipes must not hang completion. Clean only owned resources.
- Preserve unrelated changes. Commit/push, publication, installation, PATH changes, and changes outside this repository require authorization.
- Use synthetic inputs and owned temporary directories. Tests must not require a business application, database, or IIS. Keep raw logs private.
- Run dependent builds/tests sequentially. Reuse saved reports. NoBuild/NoRestore require matching outputs and dependencies.
- Report the checks actually run and any failures, skips, or blockers. Do not infer runtime support from compilation or historical results.
- Keep the complete reusable dotcheck AGENTS section in README synchronized with the CLI contract.
