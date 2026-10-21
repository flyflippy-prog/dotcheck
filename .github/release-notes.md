First public release of dotcheck, a .NET 10 CLI for Windows x64.

- Run builds and tests with bounded diagnostics and native exit-code handling.
- Inspect TRX reports and saved journals without repeating test runs.
- Control timeouts, cancellation, report retention, and owned Windows processes.

Download `dotcheck-1.0.0-win-x64.zip` and compare its SHA-256 with the accompanying
`.sha256` file. Extract the complete archive, including LICENSE, NOTICE, and the
Microsoft .NET license/third-party notices. No separate .NET runtime or PowerShell
installation is required; Build/Run require the SDK selected by your project.

The ZIP contains the managed Windows x64 build. CI also verifies Native AOT on
Windows x64. ARM64, other operating systems, and Microsoft.Testing.Platform
integration are unverified.

See README.md for usage and SECURITY.md for vulnerability reporting.
