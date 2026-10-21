using System.Diagnostics;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Dotcheck;

internal static partial class Runner
{
    static string ResolveDotnet()
    {
        foreach (string dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(dir))
            {
                continue;
            }

            var path = Path.Combine(dir.Trim('"'), "dotnet.exe");
            if (File.Exists(path))
            {
                return Path.GetFullPath(path);
            }
        }
        throw new CliError("cannot_run_dotnet");
    }
    static string LockRoot(string project)
    {
        var dir = new DirectoryInfo(Directory.Exists(project) ? project : Path.GetDirectoryName(project)!);
        string fallback = dir.FullName;
        while (dir != null)
        {
            if (Directory.Exists(Path.Combine(dir.FullName, ".git")) || File.Exists(Path.Combine(dir.FullName, ".git")))
            {
                return dir.FullName;
            }

            dir = dir.Parent;
        }
        return fallback;
    }
    static string SelectRunner(Options o)
    {
        string runner = o.Get("Runner", "Auto");
        if (!new[] { "Auto", "VSTest", "MTP" }.Contains(runner, StringComparer.OrdinalIgnoreCase))
        {
            throw new CliError("invalid_arguments");
        }

        if (!runner.Equals("Auto", StringComparison.OrdinalIgnoreCase))
        {
            return runner.Equals("MTP", StringComparison.OrdinalIgnoreCase) ? "MTP" : "VSTest";
        }

        for (var dir = new DirectoryInfo(Environment.CurrentDirectory); dir != null; dir = dir.Parent)
        {
            string config = Path.Combine(dir.FullName, "global.json");
            if (!File.Exists(config))
            {
                continue;
            }

            if (new FileInfo(config).Length > 1048576)
            {
                throw new CliError("invalid_arguments");
            }

            var node = JsonNode.Parse(File.ReadAllText(config), documentOptions: new()
            {
                CommentHandling = System.Text.Json.JsonCommentHandling.Skip,
                AllowTrailingCommas = true
            });
            return node?["test"]?["runner"]?.ToString() == "Microsoft.Testing.Platform" ? "MTP" : "VSTest";
        }
        return "VSTest";
    }
    public static (Dictionary<string, object?>, int) Run(Options o)
    {
        foreach (var a in o.Array("DotnetArgs"))
        {
            // Positional projects, response files and MSBuild property overrides can bypass managed ownership.
            if (a == "--" || a.StartsWith('@') || ManagedOption().IsMatch(a) || ManagedProperty().IsMatch(a))
            {
                throw new CliError("managed_argument_override");
            }
        }
        string project = Path.GetFullPath(o.Get("Project", "."));
        if (!File.Exists(project) && !Directory.Exists(project))
        {
            throw new CliError("invalid_arguments");
        }

        string runner = SelectRunner(o), verb = o.Flag("Build") ? "build" : "test";
        string id = Guid.NewGuid().ToString("D");
        var started = DateTimeOffset.UtcNow;
        var timer = Stopwatch.StartNew();
        int timeout = o.Number("TimeoutSeconds", 600, 1, 86400);
        int nativeExit = 2;
        string condition = "";
        bool? tree = null;
        bool journalStarted = false;
        StreamWriter? log = null;
        OwnedProcess? owned = null;
        NativeCapture? capture = null;
        Task[] readers = [];
        using var cancellation = new CancellationTokenSource();
        int cancelled = 0;
        ConsoleCancelEventHandler cancel = (_, e) => { e.Cancel = true; Interlocked.Exchange(ref cancelled, 1); };
        Console.CancelKeyPress += cancel;
        Dictionary<string, object?> Entry(string ev) => new()
        {
            ["schemaVersion"] = 1,
            ["toolVersion"] = "1.0.0",
            ["runId"] = id,
            ["event"] = ev,
            ["startedUtc"] = started.ToString("o"),
            ["project"] = project,
            ["reason"] = Output.Safe(o.Get("Reason"), o.MaxChars),
            ["filter"] = Output.Safe(o.Get("Filter"), o.MaxChars),
            ["configuration"] = Output.Safe(o.Get("Configuration", "Debug"), o.MaxChars),
            ["framework"] = Output.Safe(o.Get("Framework"), o.MaxChars),
            ["noBuild"] = o.Flag("NoBuild"),
            ["noRestore"] = o.Flag("NoRestore"),
            ["runner"] = runner,
            ["timeoutSeconds"] = o.Number("TimeoutSeconds", 600, 1, 86400),
            ["verb"] = verb,
            ["dotnetArgumentCount"] = o.Array("DotnetArgs").Length
        };
        NamedLock? workLock = null;
        try
        {
            if (o.Get("JournalPath") != "")
            {
                if (!Directory.Exists(Path.GetDirectoryName(Path.GetFullPath(o.Get("JournalPath")))))
                {
                    throw new CliError("journal_parent_missing");
                }

                Journal.Append(o.Get("JournalPath"), Entry("started"));
                journalStarted = true;
            }
            workLock = new NamedLock("dotcheck-" + NamedLock.Key(o.Get("LockRoot", LockRoot(project))), 0, "build_outputs_busy");
            var psi = new ProcessStartInfo(ResolveDotnet()) { UseShellExecute = false, WorkingDirectory = Environment.CurrentDirectory };
            void Add(params string[] a)
            {
                foreach (string s in a)
                {
                    psi.ArgumentList.Add(s);
                }
            }
            Add(verb);
            if (verb == "test" && runner == "MTP")
            {
                if (Directory.Exists(project))
                {
                    throw new CliError("mtp_requires_explicit_project");
                }

                Add(Path.GetExtension(project) is ".sln" or ".slnx" ? "--solution" : "--project");
            }
            Add(project, "--configuration", o.Get("Configuration", "Debug"), "--verbosity", "quiet");
            if (o.Get("Framework") != "")
            {
                Add("--framework", o.Get("Framework"));
            }

            if (o.Flag("NoRestore"))
            {
                Add("--no-restore");
            }

            if (o.Flag("NoBuild"))
            {
                Add("--no-build");
            }

            if (verb == "build" || runner == "VSTest")
            {
                Add("-m:1", "/nodeReuse:false", "--tl:off");
            }

            if (verb == "test")
            {
                if (o.Get("ResultsDirectory") != "")
                {
                    Add("--results-directory", Path.GetFullPath(o.Get("ResultsDirectory")));
                }

                if (runner == "VSTest")
                {
                    Add("--logger", "trx", "--logger", "console;verbosity=minimal");
                    if (o.Get("Filter") != "")
                    {
                        Add("--filter", o.Get("Filter"));
                    }
                }
            }
            Add(o.Array("DotnetArgs"));
            if (verb == "test" && runner == "MTP")
            {
                Add("--", "--report-trx");
                if (o.Get("Filter") != "")
                {
                    Add("--filter", o.Get("Filter"));
                }
            }
            psi.Environment["DOTNET_CLI_UI_LANGUAGE"] = "en";
            psi.Environment["DOTNET_NOLOGO"] = "1";
            psi.Environment["DOTNET_CLI_USE_MSBUILD_SERVER"] = "0";
            psi.Environment["MSBUILDDISABLENODEREUSE"] = "1";
            if (o.Get("LogPath") != "")
            {
                log = new StreamWriter(new FileStream(Path.GetFullPath(o.Get("LogPath")), FileMode.CreateNew, FileAccess.Write, FileShare.Read), new System.Text.UTF8Encoding(false));
            }

            capture = new(o, log);
            owned = new(psi);
            readers = [capture.Read(owned.Process.StandardOutput, cancellation.Token), capture.Read(owned.Process.StandardError, cancellation.Token)];
            int heartbeat = o.Number("HeartbeatSeconds", 0, 0, 86400);
            double next = heartbeat;
            while (!owned.Process.WaitForExit(25))
            {
                if (Volatile.Read(ref cancelled) != 0)
                {
                    condition = "cancelled";
                    nativeExit = 130;
                    break;
                }
                if (capture.Limit)
                {
                    condition = capture.LimitCondition;
                    nativeExit = 125;
                    break;
                }
                if (capture.Failed)
                {
                    condition = "capture_failed";
                    nativeExit = 2;
                    break;
                }
                if (timer.Elapsed.TotalSeconds >= timeout)
                {
                    condition = "timeout";
                    nativeExit = 124;
                    break;
                }
                if (heartbeat > 0 && timer.Elapsed.TotalSeconds >= next)
                {
                    Console.Error.WriteLine($"RUNNING elapsed={(int)timer.Elapsed.TotalSeconds}s");
                    next = timer.Elapsed.TotalSeconds + heartbeat;
                }
            }
            if (condition == "")
            {
                nativeExit = owned.Process.ExitCode;
            }
        }
        catch (Exception e) { condition = e is CliError ? e.Message : "cannot_run_dotnet"; nativeExit = 2; }
        finally
        {
            if (owned != null)
            {
                tree = owned.StopAndWait();
                // Stop the job before draining: descendants may keep both pipe handles open after native parent exit.
                try
                {
                    if (!Task.WaitAll(readers, 2000))
                    {
                        cancellation.Cancel();
                        if (condition == "")
                        {
                            condition = "pipe_drain_unfinished";
                        }
                    }
                }
                catch
                {
                    if (condition == "")
                    {
                        condition = "capture_failed";
                    }
                }
                cancellation.Cancel();
                try
                {
                    Task.WaitAll(readers, 1000);
                }
                catch { }
                owned.Dispose();
            }
            try
            {
                log?.Dispose();
            }
            catch { condition = "log_write_failed"; nativeExit = 2; }
            Console.CancelKeyPress -= cancel;
        }
        // Keep the worktree lock through report inspection and journal finalization.
        using var heldLock = workLock;
        timer.Stop();
        capture ??= new(o, null);
        if (capture.Limit && condition == "")
        {
            condition = capture.LimitCondition;
            nativeExit = 125;
        }
        if (capture.Failed && condition == "")
        {
            condition = "capture_failed";
            nativeExit = 2;
        }
        if (tree is false)
        {
            condition = "process_tree_unfinished";
        }

        if (condition != "" && nativeExit == 0)
        {
            nativeExit = 2;
        }

        ReportResult? reports = null;
        string[] paths = [];
        var reportErrors = new List<string>();
        int reportExit = 0;
        if (verb == "test")
        {
            try
            {
                if (capture.Reports.Count > 0)
                {
                    paths = capture.Reports.Select(Path.GetFullPath).ToArray();
                }
                else
                {
                    string dir = o.Get("ResultsDirectory");
                    if (dir == "" && Path.GetExtension(project).Equals(".csproj", StringComparison.OrdinalIgnoreCase) && runner == "VSTest")
                    {
                        dir = Path.Combine(Path.GetDirectoryName(project)!, "TestResults");
                    }

                    if (dir != "" && Directory.Exists(dir))
                    {
                        paths = Directory.EnumerateFiles(dir, "*.trx").Where(p => File.GetLastWriteTimeUtc(p) >= started.UtcDateTime).Take(o.MaxFiles + 1).Select(Path.GetFullPath).ToArray();
                    }
                }
                if (paths.Length > o.MaxFiles)
                {
                    reportErrors.Add("too_many_reports");
                    reportExit = 2;
                    paths = [];
                }
                if (paths.Length == 0)
                {
                    reportErrors.Add("missing_trx");
                    reportExit = 2;
                }
                else
                {
                    string mode = o.Mode.ToLowerInvariant() is "summary" or "errors" or "warnings" ? "Failed" : o.Mode;
                    reports = new ReportReader(o.Copy(mode, paths, started), true).Read();
                    reportExit = reports.Exit;
                    if (reports.Payload.GetValueOrDefault("errors") is List<Dictionary<string, object?>> errors)
                    {
                        reportErrors.AddRange(errors.Select(e => e["error"]!.ToString()!));
                    }
                }
            }
            catch { reportExit = 2; reportErrors.Add("unreadable_report"); }
        }
        int exit = nativeExit != 0 ? nativeExit : reportExit;
        if (exit == 0 && capture.ErrorCount > 0)
        {
            exit = 1;
        }

        bool warningExceeded = o.Number("MaxWarningDiagnostics", -1, -1, int.MaxValue) >= 0 && capture.WarningCount > o.Number("MaxWarningDiagnostics", -1, -1, int.MaxValue);
        if (exit == 0 && warningExceeded)
        {
            exit = 1;
        }

        string outcome = condition == "timeout" ? "timeout" : capture.ErrorCount > 0 ? "build_failed" : reports?.Reports.Any(r => r.Outcome.Equals("Aborted", StringComparison.OrdinalIgnoreCase)) == true ? "aborted" : reportExit == 2 && verb == "test" && condition == "" ? "report_invalid" : condition != "" ? "runner_failed" : reports?.Reports.Any(r => r.RunErrors > 0 || r.BadRun && r.Failed == 0) == true ? "test_run_failed" : verb == "test" && exit != 0 ? "tests_failed" : nativeExit != 0 ? "build_failed" : warningExceeded ? "diagnostics_exceeded" : "passed";
        var p = new Dictionary<string, object?> { ["phase"] = verb == "test" ? "TEST" : "BUILD", ["status"] = nativeExit == 0 && reportExit == 2 ? "invalid" : exit == 0 ? "pass" : "fail", ["exit"] = exit, ["nativeExit"] = nativeExit, ["seconds"] = Math.Round(timer.Elapsed.TotalSeconds, 3), ["outcome"] = outcome, ["runId"] = id, ["processTreeCompleted"] = tree, ["warningDiagnostics"] = capture.WarningCount };
        if (verb == "test")
        {
            p["reports"] = paths;
            p["total"] = reports?.Reports.Sum(r => r.Total) ?? 0;
            p["passed"] = reports?.Reports.Sum(r => r.Passed) ?? 0;
            p["failed"] = reports?.Reports.Sum(r => r.Failed) ?? 0;
            p["skipped"] = reports?.Reports.Sum(r => r.Skipped) ?? 0;
            p["other"] = reports?.Reports.Sum(r => r.Other) ?? 0;
        }
        if (capture.ErrorCount > 0)
        {
            p["errorDiagnostics"] = capture.ErrorCount;
        }

        if (warningExceeded)
        {
            p["maxWarningDiagnostics"] = o.Number("MaxWarningDiagnostics", -1, -1, int.MaxValue);
        }

        if (condition != "")
        {
            p["condition"] = condition;
        }

        if (reportErrors.Count > 0)
        {
            p["reportErrors"] = reportErrors.Distinct().ToArray();
        }

        if (o.Get("LogPath") != "")
        {
            p["log"] = Path.GetFullPath(o.Get("LogPath"));
        }

        List<Dictionary<string, object?>> items = [];
        if (o.Mode.Equals("Warnings", StringComparison.OrdinalIgnoreCase))
        {
            items = capture.Warnings;
            p["omitted"] = capture.WarningCount - items.Count;
        }
        else if (o.Mode.Equals("Errors", StringComparison.OrdinalIgnoreCase) || exit != 0 && capture.ErrorCount > 0)
        {
            items = capture.Errors;
            p["omitted"] = capture.ErrorCount - items.Count;
        }
        else if (reports != null && (!o.Mode.Equals("Summary", StringComparison.OrdinalIgnoreCase) || exit != 0))
        {
            items = reports.Items;
            p["omitted"] = reports.Payload.GetValueOrDefault("omitted", 0);
            if (reports.Payload.ContainsKey("unranked"))
            {
                p["unranked"] = reports.Payload["unranked"];
            }
        }
        if (items.Count > 0)
        {
            p["items"] = items;
        }

        if (exit != 0 && items.Count == 0)
        {
            p["diagnostics"] = capture.Tail.ToArray();
        }

        if (journalStarted)
        {
            var entry = Entry("finished");
            entry["finishedUtc"] = DateTimeOffset.UtcNow.ToString("o");
            entry["result"] = p;
            try
            {
                Journal.Append(o.Get("JournalPath"), entry);
            }
            catch { exit = 2; p["exit"] = 2; p["status"] = "fail"; p["outcome"] = "runner_failed"; p["condition"] = "journal_write_failed"; }
        }
        return (p, exit);
    }

    [GeneratedRegex(@"^(?:-l|--logger|--results-directory|--report-trx(?:-filename)?|--project|--solution|--no-build|--no-restore|--filter|--configuration|-c|--framework|-f)(?:$|[:=])", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 250)]
    private static partial Regex ManagedOption();

    [GeneratedRegex(@"^[/\-](?:p|property):.*\b(?:Configuration|TargetFramework\w*|VSTest\w*|TestRunner\w*|OutputPath|BaseOutputPath|MSBuildProjectExtensionsPath)\s*=", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 250)]
    private static partial Regex ManagedProperty();
}
