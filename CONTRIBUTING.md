# Contributing to dotcheck

Bug reports, reproducible examples, design feedback, and code contributions are
welcome. Follow the [code of conduct](CODE_OF_CONDUCT.md) and report vulnerabilities
privately using [SECURITY.md](SECURITY.md).

## Contribution terms

Contributions intentionally submitted for inclusion use Apache-2.0 under Section 5
of [LICENSE](LICENSE), unless explicitly stated otherwise. Submit work you have the
right to contribute and disclose third-party material and its license.
Contributors retain copyright. No CLA, copyright assignment, or DCO sign-off is
required. Additional permissions for future alternative licensing require a
separate agreement before accepting the affected contribution.

## Bug reports

Include the tool version, Windows version/architecture, SDK version for Build/Run,
exact arguments, expected behavior, exit code, and a small synthetic reproduction.
Remove secrets, customer data, and private paths. Do not attach real journals or
raw build logs. Check [compatibility.md](docs/compatibility.md) for expected behavior.

## Development

Use Windows x64, the SDK in global.json, and PowerShell 7 for development scripts:

```powershell
pwsh -NoProfile -File .\scripts\verify.ps1
```

For Native AOT, install the Visual Studio C++ workload and Windows SDK, then add
`-NativeAot`. See [development.md](docs/development.md) for focused checks and
[architecture.md](docs/architecture.md) for component responsibilities.

## Pull requests

Keep changes focused and explain the user-visible problem, resulting behavior,
compatibility effects, and checks performed. Preserve reference bytes, CLI/JSON
contracts, process ownership, and bounded output. Use synthetic tests and owned
temporary resources. Distinguish passed checks from blocked or unrun checks.

Write documentation in English. Follow [AGENTS.md](AGENTS.md) when using a coding
agent. Do not commit generated files, credentials, logs, journals, or local reports.
Release packaging and WinGet submission are described in
[releasing.md](docs/releasing.md) and [winget.md](docs/winget.md).
