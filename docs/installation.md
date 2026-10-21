# Installation

## ZIP distribution

Download the Windows x64 ZIP and its `.sha256` file from
[GitHub Releases](https://github.com/flyflippy-prog/dotcheck/releases).
Compare the ZIP's SHA-256 with the published checksum before extraction:

```powershell
Get-FileHash .\dotcheck-1.0.0-win-x64.zip -Algorithm SHA256
```

Extract the complete archive into a versioned directory, such as
`C:\tools\dotcheck\1.0.0`. Keep LICENSE, NOTICE, both DOTNET license/notice files,
and the documentation with the executable. The executable is self-contained;
PowerShell and a separately installed .NET runtime are unnecessary. Build/Run
still require an appropriate .NET SDK.

Run the executable by its full path, or register the directory for the current user:

```powershell
& 'C:\tools\dotcheck\1.0.0\dotcheck.exe' -Help
& 'C:\tools\dotcheck\1.0.0\dotcheck.exe' -Install
```

`-Install` registers the current executable's directory in User PATH and records
its location in `DOTCHECK_TOOL_FILE`. It does not copy files. Registration checks
ownership and refuses a directory containing a competing dotcheck script or
command. Keep earlier versions in separate directories.

Open a new terminal after registration. If an IDE retains the old PATH, restart
it. Check command resolution before use:

```powershell
Get-Command dotcheck -All
dotcheck -Help
```

Aliases, functions, and older commands can take precedence. Use the explicit
executable path when resolution is uncertain.

## Manual removal and rollback

For a manually registered copy:

```powershell
& 'C:\tools\dotcheck\1.0.0\dotcheck.exe' -Uninstall
```

This removes owned registration, not files. Stop active runs before removing the
version directory. Re-register a retained version to roll back. Do not remove
unrelated PATH entries, commands, or reports.
