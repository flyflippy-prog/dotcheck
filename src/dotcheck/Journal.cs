using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Dotcheck;

internal sealed class NamedLock : IDisposable
{
    readonly Mutex mutex;
    bool taken;
    public static string Key(string path) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.TrimEndingDirectorySeparator(Path.GetFullPath(path)).ToLowerInvariant())));
    public NamedLock(string name, int milliseconds, string code)
    {
        mutex = new(false, name);
        try
        {
            try
            {
                taken = mutex.WaitOne(milliseconds);
            }
            catch (AbandonedMutexException) { taken = true; }
        }
        catch { mutex.Dispose(); throw; }
        if (!taken)
        {
            mutex.Dispose();
            throw new CliError(code);
        }
    }
    public void Dispose()
    {
        if (taken)
        {
            taken = false;
            try
            {
                mutex.ReleaseMutex();
            }
            finally { mutex.Dispose(); }
        }
    }
}
internal static class Journal
{
    static NamedLock Lock(string file, string code) => new("dotcheck-journal-" + Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(file).ToLowerInvariant()))).Replace('/', '_'), 5000, code);
    public static void Append(string file, Dictionary<string, object?> entry)
    {
        using var mutex = Lock(file, "journal_write_failed");
        try
        {
            using var stream = new FileStream(Path.GetFullPath(file), FileMode.Append, FileAccess.Write, FileShare.Read);
            byte[] bytes = Encoding.UTF8.GetBytes(Output.Json(entry) + Environment.NewLine);
            stream.Write(bytes);
            stream.Flush(true);
        }
        catch { throw new CliError("journal_write_failed"); }
    }
    static string Text(JsonNode? node, string key, string fallback = "") => node?[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : fallback;
    static object? Value(JsonNode? n) => n == null ? null : JsonSerializer.Deserialize(n.ToJsonString(), JsonOutputContext.Default.Object);
    static bool Has(JsonNode n, string key) => n is JsonObject o && o.ContainsKey(key);
    static bool Number(JsonNode? n, out long value)
    {
        value = 0;
        return n is JsonValue v && (v.TryGetValue<long>(out value) || v.TryGetValue<string>(out var s) && long.TryParse(s, out value));
    }
    static DateTimeOffset Time(JsonNode? node)
    {
        if (node is not JsonValue v || !v.TryGetValue<string>(out var s) || !DateTimeOffset.TryParse(s, out var time))
        {
            throw new CliError("invalid_journal");
        }

        return time;
    }
    static string Identity(JsonNode n)
    {
        var time = Time(n["startedUtc"]);
        if (!Has(n, "runId"))
        {
            return time.ToUniversalTime().ToString("o");
        }

        if (!Guid.TryParse(Text(n, "runId"), out var id) || id == Guid.Empty)
        {
            throw new CliError("invalid_journal");
        }

        return id.ToString("D");
    }
    static void ValidateResult(JsonNode s)
    {
        if (!Number(s["exit"], out long exit) || exit < int.MinValue || exit > int.MaxValue || !new[] { "pass", "fail", "invalid" }.Contains(Text(s, "status")) || (exit == 0) != (Text(s, "status") == "pass") || Text(s, "outcome") == "")
        {
            throw new CliError("invalid_journal");
        }

        if (exit == 0 && Text(s, "outcome") != "passed")
        {
            throw new CliError("invalid_journal");
        }

        foreach (var key in new[] { "total", "passed", "failed", "skipped", "other", "warningDiagnostics", "errorDiagnostics", "nativeExit" })
        {
            if (Has(s, key) && (!Number(s[key], out long n) || key != "nativeExit" && n < 0))
            {
                throw new CliError("invalid_journal");
            }
        }

        if (Has(s, "seconds") && (!double.TryParse(s["seconds"]?.ToString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var d) || !double.IsFinite(d) || d < 0))
        {
            throw new CliError("invalid_journal");
        }

        if (s["processTreeCompleted"] is { } tree && (tree is not JsonValue tv || !tv.TryGetValue<bool>(out _)))
        {
            throw new CliError("invalid_journal");
        }

        if (s["reports"] is { } reports && (reports is not JsonArray a || a.Any(n => n is not JsonValue v || !v.TryGetValue<string>(out _))))
        {
            throw new CliError("invalid_journal");
        }

        if (exit == 0 && Number(s["nativeExit"], out var native) && native != 0)
        {
            throw new CliError("invalid_journal");
        }

        if (exit == 0 && new[] { "failed", "other", "errorDiagnostics" }.Any(key => Number(s[key], out var n) && n > 0))
        {
            throw new CliError("invalid_journal");
        }

        string[] counters = ["total", "passed", "failed", "skipped", "other"];
        if (counters.All(key => Has(s, key)))
        {
            try
            {
                long sum = 0;
                foreach (string key in counters[1..])
                {
                    Number(s[key], out long count);
                    sum = checked(sum + count);
                }
                Number(s["total"], out long total);
                if (sum != total)
                {
                    throw new CliError("invalid_journal");
                }
            }
            catch (OverflowException) { throw new CliError("invalid_journal"); }
        }
    }
    static void NoDuplicateKeys(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var keys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var p in element.EnumerateObject())
            {
                if (!keys.Add(p.Name))
                {
                    throw new CliError("invalid_journal");
                }

                NoDuplicateKeys(p.Value);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var child in element.EnumerateArray())
            {
                NoDuplicateKeys(child);
            }
        }
    }
    public static (Dictionary<string, object?>, int) Inspect(Options o)
    {
        string snapshot;
        using (Lock(o.Get("JournalPath"), "journal_busy"))
        {
            try
            {
                using var stream = new FileStream(o.Get("JournalPath"), FileMode.Open, FileAccess.Read, FileShare.Read);
                if (stream.Length > o.MaxLogBytes)
                {
                    throw new CliError("invalid_journal");
                }

                using var buffer = new MemoryStream();
                byte[] bytes = new byte[8192];
                int n;
                while ((n = stream.Read(bytes)) != 0)
                {
                    if (buffer.Length + n > o.MaxLogBytes)
                    {
                        throw new CliError("invalid_journal");
                    }

                    buffer.Write(bytes, 0, n);
                }
                snapshot = new UTF8Encoding(false, true).GetString(buffer.GetBuffer().AsSpan(0, checked((int)buffer.Length))).TrimStart('\uFEFF');
            }
            catch { throw new CliError("invalid_journal"); }
        }
        var runs = new Dictionary<string, (JsonNode Start, JsonNode? Finish, bool Orphan)>(StringComparer.OrdinalIgnoreCase);
        string? latest = null;
        using var reader = new StringReader(snapshot);
        string? line;
        while ((line = reader.ReadLine()) != null)
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            JsonNode e;
            try
            {
                using var doc = JsonDocument.Parse(line);
                NoDuplicateKeys(doc.RootElement);
                e = JsonNode.Parse(line) ?? throw new Exception();
                if (e is not JsonObject)
                {
                    throw new Exception();
                }
            }
            catch { throw new CliError("invalid_journal"); }
            if (Has(e, "schemaVersion") && (!Number(e["schemaVersion"], out var schema) || schema != 1))
            {
                throw new CliError("unsupported_journal_schema");
            }

            string key = Identity(e), ev = Text(e, "event");
            if (ev == "started")
            {
                if (runs.ContainsKey(key) || runs.Count >= 10000)
                {
                    throw new CliError("invalid_journal");
                }

                runs[key] = (e, null, false);
                latest = key;
            }
            else if (ev == "finished")
            {
                if (e["result"] is not JsonObject s)
                {
                    throw new CliError("invalid_journal");
                }

                ValidateResult(s);
                if (!runs.ContainsKey(key) && (!Has(e, "toolVersion") || Text(e, "toolVersion") == "1.1.0") && Text(s, "condition") == "build_outputs_busy" && Number(s["exit"], out var exit) && exit == 2 && Text(s, "status") == "fail" && Text(s, "outcome") == "runner_failed" && Has(s, "processTreeCompleted") && s["processTreeCompleted"] == null)
                {
                    if (runs.Count >= 10000)
                    {
                        throw new CliError("invalid_journal");
                    }

                    runs[key] = (e, null, true);
                    latest = key;
                }
                if (!runs.TryGetValue(key, out var record) || record.Finish != null || Time(record.Start["startedUtc"]) != Time(e["startedUtc"]))
                {
                    throw new CliError("invalid_journal");
                }

                runs[key] = (record.Start, e, record.Orphan);
            }
            else
            {
                throw new CliError("invalid_journal");
            }
        }
        string selected = o.Get("RunId", latest ?? "");
        if (Guid.TryParse(selected, out var guid))
        {
            selected = guid.ToString("D");
        }
        else if (DateTimeOffset.TryParse(selected, out var date))
        {
            selected = date.ToUniversalTime().ToString("o");
        }

        if (!runs.TryGetValue(selected, out var run))
        {
            throw new CliError("journal_run_not_found");
        }

        int code = 1;
        var p = new Dictionary<string, object?> { ["runId"] = selected, ["startedUtc"] = Text(run.Start, "startedUtc"), ["status"] = "unconfirmed", ["outcome"] = "unfinished", ["reportVerification"] = "not_attempted" };
        if (run.Orphan)
        {
            p["startEventMissing"] = true;
        }

        foreach (var field in new[] { "project", "reason", "filter", "configuration", "framework", "runner", "verb" })
        {
            if (Has(run.Start, field))
            {
                p[field] = Output.Safe(Text(run.Start, field), o.MaxChars);
            }
        }

        if (run.Finish != null)
        {
            var saved = run.Finish["result"]!;
            Number(saved["exit"], out var recorded);
            code = (int)recorded;
            p["status"] = Text(saved, "status");
            p["outcome"] = Output.Safe(Text(saved, "outcome"), o.MaxChars);
            p["recordedExit"] = code;
            foreach (var field in new[] { "seconds", "total", "passed", "failed", "skipped", "warningDiagnostics", "errorDiagnostics", "nativeExit", "processTreeCompleted" })
            {
                if (Has(saved, field))
                {
                    p[field] = Value(saved[field]);
                }
            }

            if (saved["processTreeCompleted"]?.ToJsonString() == "false")
            {
                if (code == 0)
                {
                    code = 1;
                }

                p["status"] = "fail";
            }
            var diagnostics = new List<Dictionary<string, object?>>();
            string mode = o.Mode.ToLowerInvariant();
            if (saved["items"] is JsonArray items)
            {
                foreach (var item in items)
                {
                    if (item is not JsonObject || !Has(item, "code"))
                    {
                        continue;
                    }

                    string level = Text(item, "level", "unknown");
                    if (level is not ("error" or "warning"))
                    {
                        level = "unknown";
                        if (Number(saved["errorDiagnostics"], out var ec) && ec > 0 && Number(saved["warningDiagnostics"], out var wc) && wc == 0 && Text(saved, "outcome") == "build_failed")
                        {
                            level = "error";
                        }
                        else if (Text(saved, "outcome") is "passed" or "diagnostics_exceeded")
                        {
                            level = "warning";
                        }
                    }
                    if (mode == "errors" && level != "error" || mode == "warnings" && level != "warning")
                    {
                        continue;
                    }

                    var row = new Dictionary<string, object?> { ["level"] = level };
                    foreach (var field in new[] { "code", "location", "message" })
                    {
                        if (Has(item, field))
                        {
                            row[field] = Output.Safe(Text(item, field), o.MaxChars);
                        }
                    }

                    if (diagnostics.Count < o.Top)
                    {
                        diagnostics.Add(row);
                    }
                }
            }

            if (diagnostics.Count > 0 && (mode is "errors" or "warnings" || mode == "summary" && code != 0))
            {
                p["recordedDiagnostics"] = diagnostics;
            }
            else if (mode == "summary" && code != 0 && saved["diagnostics"] is JsonArray tail)
            {
                p["recordedDiagnostics"] = tail.Take(o.Top).Select(n => new Dictionary<string, object?> { ["message"] = Output.Safe(n?.ToString(), o.MaxChars) }).ToList();
            }

            if (mode is "errors" or "warnings")
            {
                p["diagnosticsAvailable"] = diagnostics.Count > 0;
            }

            if (Has(saved, "log"))
            {
                p["log"] = Output.Safe(Text(saved, "log"), o.MaxChars);
                p["logAvailable"] = File.Exists(Text(saved, "log"));
            }
            string[] reports = saved["reports"] is JsonArray array ? array.Select(n => n!.GetValue<string>()).ToArray() : [];
            if (reports.Length > o.MaxFiles)
            {
                throw new CliError("too_many_reports");
            }

            p["reports"] = reports.Select(s => Output.Safe(s, o.MaxChars)).ToArray();
            if (reports.Length > 0)
            {
                var result = new ReportReader(o.Copy(mode is "errors" or "warnings" ? "Summary" : o.Mode, reports, Time(run.Start["startedUtc"]))).Read();
                p["inspection"] = result.Payload;
                p["reportVerification"] = result.Exit == 0 ? "checked" : "failed";
                if (result.Exit != 0)
                {
                    if (code == 0)
                    {
                        code = result.Exit;
                    }

                    p["status"] = code == 2 ? "invalid" : "fail";
                }
            }
            else if (Text(run.Start, "verb") == "build" || Text(run.Finish, "verb") == "build" || Text(saved, "phase") == "BUILD")
            {
                p["reportVerification"] = "not_applicable";
                if (mode is not ("summary" or "errors" or "warnings"))
                {
                    throw new CliError("journal_run_has_no_reports");
                }
            }
            else
            {
                p["reportVerification"] = "unavailable";
                if (code == 0)
                {
                    code = 2;
                    p["status"] = "invalid";
                }
                if (mode is not ("summary" or "errors" or "warnings"))
                {
                    throw new CliError("journal_run_has_no_reports");
                }
            }
        }
        p["exit"] = code;
        return (p, code);
    }
}
