# Security policy

## Scope

dotcheck is a local build/test and report-inspection tool. Building or testing a
project executes that project's build targets and test code with your permissions.
Only run projects you trust. dotcheck is not an execution sandbox.

TRX files and journals may contain sensitive data. Display redaction is best
effort. Explicit raw logs can contain secrets; keep them private. A saved journal
is not a tamper-proof audit trail or proof that current sources passed.

## Reporting a vulnerability

Use [Report a vulnerability](https://github.com/flyflippy-prog/dotcheck/security/advisories/new)
to contact the maintainer privately. Include the affected version, impact,
prerequisites, and a minimal synthetic reproduction.

If private reporting is unavailable, use a private contact explicitly published
by the maintainer on their GitHub profile. If no private contact is available,
open an issue asking for a private security contact without describing the exploit
or attaching sensitive data.

Do not disclose exploit details, credentials, real customer reports, or raw logs
in public issues or pull requests. Do not test against systems you do not own.

## Maintenance status

Security fixes target the current Windows x64 release line. There is no promised
response time or maintenance commitment for older versions. Other
operating systems, ARM64, and actual MTP are not verified targets. Windows x64
Native AOT passes CI; ZIP distribution currently uses the managed build.

Release checks are recorded in [the publication checklist](docs/releasing.md).
