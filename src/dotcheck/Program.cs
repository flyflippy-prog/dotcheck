using Dotcheck;

if (args.Length > 0 && args[0] == "--internal-worker")
{
    return OwnedProcess.Worker(args[1..]);
}

Options? options = null;
try
{
    options = Options.Parse(args);
    options.Validate();
    (Dictionary<string, object?> Payload, int Exit) result;
    if (options.Flag("Help"))
    {
        result = (new()
        {
            ["help"] = new[] {
        "dotcheck 1.0.0 (.NET 10, Windows x64); no PowerShell runtime dependency.",
        "dotcheck -Path <file.trx|directory> [-Recurse] [-NotBefore <ISO-date>] [-FailOnSkipped]",
        "dotcheck -Build|-Run -Project <project> [-Configuration Debug] [-Framework <TFM>] [-Filter <expression>]",
        "-Mode Summary|Failed|Skipped|Slow|Detail|RunErrors|Errors|Warnings; Detail requires -Test <literal>.",
        "-Top 5 (1..100); -MaxChars 350 (32..4096); -StackLines 0 (0..20, Detail only); -Json.",
        "-TimeoutSeconds 600; -MaxLogMiB 64; -HeartbeatSeconds 0 (stderr elapsed only).",
        "-NoBuild/-NoRestore require matching outputs/dependencies; -DotnetArgs takes separate argv tokens.",
        "-ResultsDirectory is relative to caller; native defaults preserved; no automatic cleanup.",
        "-JournalPath <private.jsonl> -Reason <reason>; -LastRun|-RunId <GUID|legacy-start> never launches dotnet.",
        "-Clean -ResultsDirectory <owned-directory> [-KeepReports 10]; 0 deletes all eligible top-level TRX.",
        "-Install|-Uninstall: owned User PATH registration only; explicit action, no file replacement.",
        "Exit 0 healthy, 1 failure, 2 invalid; native nonzero preserved; timeout 124, output limit 125.",
        "Runner Auto|VSTest|MTP; actual MTP is a separate unverified gate. See README.md." }
        }, 0);
    }
    else if (options.Flag("LastRun") || options.Get("RunId") != "")
    {
        result = Journal.Inspect(options);
    }
    else if (options.Flag("Build") || options.Flag("Run"))
    {
        result = Runner.Run(options);
    }
    else if (options.Flag("Clean"))
    {
        result = Setup.Clean(options);
    }
    else if (options.Flag("Install") || options.Flag("Uninstall"))
    {
        result = Setup.Register(options);
    }
    else
    {
        var r = new ReportReader(options).Read();
        result = (r.Payload, r.Exit);
    }
    Output.Emit(result.Payload, options);
    return result.Exit;
}
catch (Exception e)
{
    var payload = new Dictionary<string, object?> { ["status"] = "invalid", ["error"] = e is CliError ? e.Message : "processing_error" };
    if (e is CliError { Diagnostic: not null } ce)
    {
        payload["diagnostic"] = ce.Diagnostic;
    }

    Output.Emit(payload, options ?? Options.Parse(Options.WantsJson(args) ? ["-Json"] : []));
    return 2;
}
