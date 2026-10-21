using System.Text.Json;
using System.Text.RegularExpressions;

namespace Dotcheck;

internal static partial class Output
{
    const int MaxDiagnosticCharacters = 32768;

    public static string Safe(string? value, int limit = 350)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(limit, 3);
        string s = value ?? "";
        // Never regex or display a prefix of an oversized untrusted XML/JSON value.
        if (s.Length > MaxDiagnosticCharacters)
        {
            s = "[diagnostic omitted: oversized input]";
        }

        s = Authorization().Replace(s, "$1 [redacted]");
        s = Jwt().Replace(s, "[redacted]");
        s = Secret().Replace(s, "$1=[redacted]");
        s = UrlCredentials().Replace(s, "$1[redacted]@");
        s = UrlQuery().Replace(s, "$1?[redacted]");
        s = Whitespace().Replace(s, " ").Trim();
        return s.Length > limit ? s[..(limit - 3)] + "..." : s;
    }
    public static string Json(object payload) => JsonSerializer.Serialize(payload, JsonOutputContext.Default.Object);

    [GeneratedRegex(@"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 250)]
    private static partial Regex Authorization();

    [GeneratedRegex(@"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b", RegexOptions.CultureInvariant, 250)]
    private static partial Regex Jwt();

    [GeneratedRegex("\\b(password|pwd|secret|token|api[-_]?key|access[-_]?key|authorization|connection[-_]?string)[\"']?\\s*[:=]\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s,;]+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 250)]
    private static partial Regex Secret();

    [GeneratedRegex(@"(https?://)[^\s/@]+:[^\s/@]+@", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 250)]
    private static partial Regex UrlCredentials();

    [GeneratedRegex(@"(https?://[^\s?#]+)\?[^\s#]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 250)]
    private static partial Regex UrlQuery();

    [GeneratedRegex(@"[\p{Cc}\p{Cf}\s]+", RegexOptions.CultureInvariant, 250)]
    private static partial Regex Whitespace();
    public static void Emit(Dictionary<string, object?> p, Options o)
    {
        if (o.Flag("Json"))
        {
            Console.WriteLine(Json(p));
            return;
        }
        if (p.TryGetValue("help", out var help))
        {
            foreach (var line in (string[])help!)
            {
                Console.WriteLine(line);
            }

            return;
        }
        if (p.ContainsKey("error"))
        {
            Console.WriteLine($"INVALID {p["error"]}");
            if (p.TryGetValue("diagnostic", out var d))
            {
                Console.WriteLine(Json(d!));
            }

            return;
        }
        string status = p.GetValueOrDefault("status")?.ToString()?.ToUpperInvariant() ?? "";
        if (p.ContainsKey("deleted"))
        {
            Console.WriteLine($"CLEAN deleted={p["deleted"]} skipped={p["skipped"]}");
            return;
        }
        if (p.ContainsKey("reportVerification"))
        {
            Console.WriteLine($"RUN {status} id={p["runId"]} outcome={p["outcome"]} reportVerification={p["reportVerification"]} exit={p["exit"]}");
        }
        else if (p.ContainsKey("phase"))
        {
            Console.WriteLine($"{p["phase"]} {status} outcome={p["outcome"]} treeCompleted={p["processTreeCompleted"]} " + Fields(p, "total", "passed", "failed", "skipped", "warningDiagnostics", "seconds", "exit", "condition"));
        }
        else if (o.Mode.Equals("Summary", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine(status + " " + Fields(p, "reports", "total", "passed", "failed", "skipped", "other", "runErrors", "invalid", "sumReportSeconds"));
        }
        else
        {
            Console.WriteLine(status + " " + Fields(p, "matched", "omitted", "unranked"));
        }

        Rows(p, "items");
        Rows(p, "recordedDiagnostics");
        Rows(p, "errors");
        if (p.TryGetValue("diagnostics", out var diagnostics) && diagnostics is IEnumerable<string> lines)
        {
            foreach (var line in lines)
            {
                Console.WriteLine(line);
            }
        }

        if (p.TryGetValue("inspection", out var inspection) && inspection is Dictionary<string, object?> ip)
        {
            Rows(ip, "items");
        }

        if (p.GetValueOrDefault("diagnosticsAvailable") is false)
        {
            Console.WriteLine("No matching compiler diagnostics retained; this does not establish zero warnings/errors.");
        }
    }
    static string Fields(Dictionary<string, object?> p, params string[] keys) => string.Join(' ', keys.Where(p.ContainsKey).Select(k => $"{k}={p[k]}"));
    static void Rows(Dictionary<string, object?> p, string key)
    {
        if (p.GetValueOrDefault(key) is IEnumerable<Dictionary<string, object?>> rows)
        {
            foreach (var r in rows)
            {
                Console.WriteLine(string.Join(" | ", r.Where(k => k.Key != "report").Select(k => $"{k.Key}={k.Value}")));
            }
        }
    }
}
