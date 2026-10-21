# Changelog

## Unreleased — 1.0.0

Initial release.

### Features

- Self-contained .NET 10 CLI for Windows x64 with no PowerShell runtime dependency.
- Build/test execution with bounded diagnostics, native exit codes, timeouts,
  cancellation, worktree locking, and Windows process-tree ownership.
- TRX validation and inspection, legacy journal reading, and explicit report cleanup.
- Apache-2.0 licensing with separate Microsoft .NET license materials.

### Compatibility

- Retains the PowerShell-style CLI and schemaVersion=1 journal format.
- Rejects inconsistent reports and saved results, compiler errors reported with
  native exit 0, and attempts to override managed build options.
- Bounds diagnostic retention and normalizes equivalent worktree lock paths.

See [the compatibility contract](docs/compatibility.md) and
[development guide](docs/development.md) for verification commands.
