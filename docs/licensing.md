# Licensing and third-party notices

dotcheck's own C#, PowerShell, tests, fixtures, scripts, and documentation are
licensed under [Apache-2.0](../LICENSE). This includes the captured original
PowerShell implementation. [NOTICE](../NOTICE) records copyright and project origin.
The root license applies without rewriting immutable reference files or adding
large headers to every source file. New independently distributed files may use
`SPDX-License-Identifier: Apache-2.0` in the language's comment syntax.

## Microsoft .NET

The CLI targets .NET 10 and uses the BCL without additional runtime NuGet packages.
Self-contained ZIPs include Microsoft .NET components under their own licenses.
Packaging reads the bundled runtime version and copies that runtime pack's
LICENSE.TXT and THIRD-PARTY-NOTICES.TXT as:

- DOTNET-LICENSE.TXT
- DOTNET-THIRD-PARTY-NOTICES.TXT

These accompany dotcheck's LICENSE and NOTICE. Apache-2.0 does not relicense
Microsoft components or their dependencies. MSTest and Microsoft.NET.Test.Sdk
are test-only dependencies with their own terms.

Contributors retain copyright and submit contributions under Apache-2.0;
[CONTRIBUTING.md](../CONTRIBUTING.md) describes the contribution policy.
