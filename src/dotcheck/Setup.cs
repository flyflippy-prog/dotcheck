using System.Diagnostics;

namespace Dotcheck;

internal interface IRegistrationEnvironment
{
    string? Get(string name, EnvironmentVariableTarget target);
    void Set(string name, string? value, EnvironmentVariableTarget target);
    bool Owned(string file);
}
internal sealed class RegistrationEnvironment : IRegistrationEnvironment
{
    public string? Get(string name, EnvironmentVariableTarget target) => Environment.GetEnvironmentVariable(name, target);
    public void Set(string name, string? value, EnvironmentVariableTarget target) => Environment.SetEnvironmentVariable(name, value, target);
    public bool Owned(string file)
    {
        try
        {
            var v = FileVersionInfo.GetVersionInfo(file);
            return Path.GetFileName(file).Equals("dotcheck.exe", StringComparison.OrdinalIgnoreCase) && v.ProductName == "dotcheck" && v.FileDescription == "Bounded native .NET build/test and TRX inspection CLI";
        }
        catch { return false; }
    }
}
internal static class Setup
{
    public static (Dictionary<string, object?>, int) Clean(Options o)
    {
        if (o.Get("ResultsDirectory") == "")
        {
            throw new CliError("invalid_arguments");
        }

        int keep = o.Number("KeepReports", 10, 0, 10000);
        var root = new DirectoryInfo(Path.GetFullPath(o.Get("ResultsDirectory")));
        if (!root.Exists || (root.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new CliError("unsafe_run_store");
        }

        for (var ancestor = root.Parent; ancestor != null; ancestor = ancestor.Parent)
        {
            if ((ancestor.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new CliError("unsafe_run_store");
            }
        }

        int deleted = 0, skipped = 0;
        foreach (var f in root.EnumerateFiles("*.trx", SearchOption.TopDirectoryOnly).OrderByDescending(f => f.LastWriteTimeUtc).ThenByDescending(f => f.Name, StringComparer.OrdinalIgnoreCase).Skip(keep))
        {
            if (!Path.GetDirectoryName(Path.GetFullPath(f.FullName))!.Equals(root.FullName, StringComparison.OrdinalIgnoreCase))
            {
                throw new CliError("unsafe_run_store");
            }

            if ((f.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                skipped++;
                continue;
            }
            try
            {
                using var stream = new FileStream(f.FullName, FileMode.Open, FileAccess.ReadWrite, FileShare.None, 4096, FileOptions.DeleteOnClose);
                deleted++;
            }
            catch { skipped++; }
        }
        return (new()
        {
            ["deleted"] = deleted,
            ["skipped"] = skipped
        }, skipped > 0 ? 1 : 0);
    }
    static string Normalize(string? s)
    {
        try
        {
            return string.IsNullOrWhiteSpace(s) ? "" : Path.GetFullPath(Environment.ExpandEnvironmentVariables(s.Trim().Trim('"'))).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }
        catch { return ""; }
    }
    public static (Dictionary<string, object?>, int) Register(Options o, IRegistrationEnvironment? environment = null, string? executable = null)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new CliError("path_action_windows_only");
        }

        environment ??= new RegistrationEnvironment();
        executable ??= Environment.ProcessPath!;
        if (!environment.Owned(executable))
        {
            throw new CliError("path_install_failed");
        }

        using var setupLock = new NamedLock("dotcheck-path-registration", 5000, "path_install_failed");
        string root = Path.GetDirectoryName(Path.GetFullPath(executable))!;
        var owned = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { Normalize(root) };
        var keys = new[] { ("PATH", EnvironmentVariableTarget.Process), ("DOTCHECK_TOOL_FILE", EnvironmentVariableTarget.Process), ("PATH", EnvironmentVariableTarget.User), ("DOTCHECK_TOOL_FILE", EnvironmentVariableTarget.User) };
        var old = keys.ToDictionary(k => k, k => environment.Get(k.Item1, k.Item2));
        foreach (var kv in old)
        {
            if (kv.Key.Item1 == "DOTCHECK_TOOL_FILE" && kv.Value != null && environment.Owned(kv.Value))
            {
                owned.Add(Normalize(Path.GetDirectoryName(kv.Value)));
            }

            if (kv.Key.Item1 == "PATH")
            {
                foreach (var dir in (kv.Value ?? "").Split(';'))
                {
                    string n = Normalize(dir);
                    if (n != "" && environment.Owned(Path.Combine(n, "dotcheck.exe")))
                    {
                        owned.Add(n);
                    }
                }
            }
        }
        bool install = o.Flag("Install");
        var next = keys.ToDictionary(k => k, k => old[k]);
        foreach (var key in keys)
        {
            if (key.Item1 == "PATH")
            {
                var entries = (old[key] ?? "").Split(';').Where(e => e != "" && !owned.Contains(Normalize(e))).ToList();
                if (install)
                {
                    entries.Insert(0, root);
                }

                next[key] = string.Join(';', entries);
            }
            else if (install)
            {
                next[key] = Path.GetFullPath(executable);
            }
            else if (old[key] != null && environment.Owned(old[key]!))
            {
                next[key] = null;
            }
        }
        // A foreign file in our directory would shadow the exe in shells with different extension precedence.
        if (install && new[] { "dotcheck.cmd", "dotcheck.bat", "dotcheck.ps1", "dotcheck.com" }.Any(f => File.Exists(Path.Combine(root, f))))
        {
            throw new CliError("command_shadowed");
        }

        var written = new List<(string, EnvironmentVariableTarget)>();
        try
        {
            foreach (var key in keys)
            {
                if (old[key] != next[key])
                {
                    environment.Set(key.Item1, next[key], key.Item2);
                    written.Add(key);
                }
            }
        }
        catch
        {
            bool failed = false;
            foreach (var key in written.AsEnumerable().Reverse())
            {
                try
                {
                    if (environment.Get(key.Item1, key.Item2) == next[key])
                    {
                        environment.Set(key.Item1, old[key], key.Item2);
                    }
                    else if (environment.Get(key.Item1, key.Item2) != old[key])
                    {
                        failed = true;
                    }
                }
                catch { failed = true; }
            }
            throw new CliError(failed ? "path_rollback_failed" : "path_install_failed");
        }
        return (new()
        {
            ["status"] = install ? "installed" : "uninstalled",
            ["path"] = root,
            ["changed"] = keys.Any(k => k.Item2 == EnvironmentVariableTarget.User && old[k] != next[k]),
            ["restartShell"] = old[("PATH", EnvironmentVariableTarget.User)] != next[("PATH", EnvironmentVariableTarget.User)]
        }, 0);
    }
}
