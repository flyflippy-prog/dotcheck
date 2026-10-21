using System.Globalization;

namespace Dotcheck;

internal sealed class CliError(string code, object? diagnostic = null) : Exception(code)
{
    public object? Diagnostic { get; } = diagnostic;
}

internal sealed class Options
{
    readonly Dictionary<string, List<string>> values = new(StringComparer.OrdinalIgnoreCase);
    static readonly HashSet<string> switches = new("Json Recurse FailOnSkipped Help Install Uninstall Build Run Clean NoRestore NoBuild LastRun".Split(' '), StringComparer.OrdinalIgnoreCase);
    static readonly HashSet<string> names = new("Path Mode Test Top MaxChars StackLines Project Configuration Framework Filter Runner DotnetArgs TimeoutSeconds ResultsDirectory LogPath JournalPath RunId HeartbeatSeconds Reason LockRoot MaxWarningDiagnostics KeepReports MaxLogMiB NotBefore MaxFiles MaxFileMiB".Split(' ').Concat(switches), StringComparer.OrdinalIgnoreCase);
    public string Get(string key, string fallback = "") => values.TryGetValue(key, out var v) ? v.Last() : fallback;
    public bool Has(string key) => values.ContainsKey(key);
    public bool Flag(string key) => bool.TryParse(Get(key), out var b) && b;
    public static bool WantsJson(string[] args)
    {
        bool json = false;
        foreach (var a in args)
        {
            var parts = a.TrimStart('-').Split(':', 2);
            if (a.StartsWith('-') && parts[0].Equals("Json", StringComparison.OrdinalIgnoreCase))
            {
                json = parts.Length == 1 || parts[1].TrimStart('$').Equals("true", StringComparison.OrdinalIgnoreCase);
            }
        }
        return json;
    }
    public string[] Array(string key) => values.TryGetValue(key, out var v) ? v.ToArray() : [];
    public int Number(string key, int fallback, int min, int max)
    {
        if (!int.TryParse(Get(key, fallback.ToString(CultureInfo.InvariantCulture)), NumberStyles.Integer, CultureInfo.InvariantCulture, out int n))
        {
            throw new CliError("invalid_arguments");
        }

        if (n < min || n > max)
        {
            throw new CliError("invalid_arguments", new Dictionary<string, object?> { ["message"] = $"{key}={n} must be between {min} and {max} (inclusive).", ["argument"] = key, ["value"] = n, ["minimum"] = min, ["maximum"] = max });
        }

        return n;
    }
    public int Top => Number("Top", 5, 1, 100);
    public int MaxChars => Number("MaxChars", 350, 32, 4096);
    public int StackLines => Number("StackLines", 0, 0, 20);
    public int MaxFiles => Number("MaxFiles", 100, 1, 10000);
    public long MaxFileBytes => (long)Number("MaxFileMiB", 128, 1, 1024) * 1048576;
    public long MaxLogBytes => (long)Number("MaxLogMiB", 64, 1, 1024) * 1048576;
    public string Mode => Get("Mode", "Summary");
    public DateTimeOffset? NotBefore => Has("NotBefore") ? ParseDate(Get("NotBefore")) : null;
    public static DateTimeOffset ParseDate(string s) => DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var d) || DateTimeOffset.TryParse(s, CultureInfo.CurrentCulture, DateTimeStyles.AllowWhiteSpaces, out d) ? d : throw new CliError("invalid_arguments");
    public Options Copy(string? mode = null, string[]? paths = null, DateTimeOffset? notBefore = null)
    {
        var o = new Options();
        foreach (var kv in values)
        {
            o.values[kv.Key] = new(kv.Value);
        }

        if (mode != null)
        {
            o.values["Mode"] = [mode];
        }

        if (paths != null)
        {
            o.values["Path"] = new(paths);
        }

        if (notBefore != null)
        {
            o.values["NotBefore"] = [notBefore.Value.ToString("o")];
        }

        return o;
    }
    public static Options Parse(string[] args)
    {
        var o = new Options();
        for (int i = 0; i < args.Length; i++)
        {
            if (!args[i].StartsWith('-'))
            {
                throw new CliError("invalid_arguments");
            }

            var parts = args[i].TrimStart('-').Split(':', 2);
            string key = parts[0].ToLowerInvariant() switch
            {
                "p" => "Path",
                "h" or "?" => "Help",
                _ => parts[0]
            };
            if (!names.Contains(key))
            {
                throw new CliError("invalid_arguments");
            }

            if (switches.Contains(key))
            {
                var s = parts.Length == 1 ? "true" : parts[1].TrimStart('$');
                if (!bool.TryParse(s, out _))
                {
                    throw new CliError("invalid_arguments");
                }

                o.values[key] = [s];
                continue;
            }
            var list = new List<string>();
            if (parts.Length == 2)
            {
                list.Add(parts[1]);
            }
            else if (++i < args.Length)
            {
                list.Add(args[i]);
            }
            else
            {
                throw new CliError("invalid_arguments");
            }

            if (key.Equals("Path", StringComparison.OrdinalIgnoreCase) || key.Equals("DotnetArgs", StringComparison.OrdinalIgnoreCase))
            {
                // Native arrays are separate argv tokens. DotnetArgs consumes until a known CLI option.
                while (i + 1 < args.Length && !IsOption(args[i + 1], key))
                {
                    list.Add(args[++i]);
                }

                if (o.values.TryGetValue(key, out var prior))
                {
                    prior.AddRange(list);
                }
                else
                {
                    o.values[key] = list;
                }
            }
            else
            {
                if (o.Has(key))
                {
                    throw new CliError("invalid_arguments");
                }

                o.values[key] = list;
            }
        }
        return o;
    }
    static bool IsOption(string s, string key) => s.StartsWith('-') && (key.Equals("Path", StringComparison.OrdinalIgnoreCase) || names.Contains(s.TrimStart('-').Split(':')[0]) || s is "-p" or "-h" or "-?");
    public void Validate()
    {
        if (new[] { "Build", "Run", "Clean", "Install", "Uninstall", "LastRun" }.Count(Flag) + (Get("RunId") != "" ? 1 : 0) > 1)
        {
            throw new CliError("invalid_arguments", new Dictionary<string, object?> { ["message"] = "Choose only one action: Install, Uninstall, Build, Run, Clean, LastRun or RunId." });
        }

        if (Flag("Help"))
        {
            return;
        }

        _ = Top;
        _ = MaxChars;
        _ = StackLines;
        _ = MaxFiles;
        _ = MaxFileBytes;
        _ = MaxLogBytes;
        _ = NotBefore;
        _ = Number("HeartbeatSeconds", 0, 0, 86400);
        _ = Number("TimeoutSeconds", 600, 1, 86400);
        _ = Number("MaxWarningDiagnostics", -1, -1, int.MaxValue);
        if (!new[] { "Summary", "Failed", "Skipped", "Slow", "Detail", "RunErrors", "Errors", "Warnings" }.Contains(Mode, StringComparer.OrdinalIgnoreCase))
        {
            throw new CliError("invalid_arguments");
        }

        if (StackLines > 0 && !Mode.Equals("Detail", StringComparison.OrdinalIgnoreCase))
        {
            throw new CliError("invalid_arguments");
        }

        if (Mode.Equals("Detail", StringComparison.OrdinalIgnoreCase) && Get("Test") == "")
        {
            throw new CliError("invalid_arguments");
        }

        if (Get("Test") != "" && new[] { "Summary", "RunErrors", "Errors", "Warnings" }.Contains(Mode, StringComparer.OrdinalIgnoreCase))
        {
            throw new CliError("invalid_arguments");
        }

        bool runner = Flag("Build") || Flag("Run"), journal = Flag("LastRun") || Get("RunId") != "";
        if (runner && (Array("Path").Length > 0 || Get("JournalPath") != "" && string.IsNullOrWhiteSpace(Get("Reason"))))
        {
            throw new CliError("invalid_arguments");
        }

        if (!runner && Number("HeartbeatSeconds", 0, 0, 86400) != 0)
        {
            throw new CliError("invalid_arguments");
        }

        if (Flag("Build") && (Flag("NoBuild") || Get("Filter") != "" || Get("Test") != "" || Get("ResultsDirectory") != "" || !new[] { "Summary", "Errors", "Warnings" }.Contains(Mode, StringComparer.OrdinalIgnoreCase)))
        {
            throw new CliError("invalid_arguments");
        }

        if (journal && (Get("JournalPath") == "" || new[] { "Path", "NotBefore", "Recurse", "Reason", "LogPath", "ResultsDirectory", "NoBuild", "NoRestore", "Filter", "LockRoot", "DotnetArgs" }.Any(Has)))
        {
            throw new CliError("invalid_arguments");
        }

        if (!runner && !journal && !Flag("Help") && !Flag("Clean") && !Flag("Install") && !Flag("Uninstall") && (Array("Path").Length == 0 || new[] { "Errors", "Warnings" }.Contains(Mode, StringComparer.OrdinalIgnoreCase)))
        {
            throw new CliError("invalid_arguments");
        }

        if ((Flag("Install") || Flag("Uninstall")) && new[] { "Path", "Test", "Mode" }.Any(Has))
        {
            throw new CliError("invalid_arguments");
        }
    }
}
