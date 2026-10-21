using System.Globalization;
using System.Text;
using System.Xml;

namespace Dotcheck;

internal sealed record ReportResult(Dictionary<string, object?> Payload, int Exit, List<Report> Reports, List<Dictionary<string, object?>> Items);
internal sealed class Report
{
    public string Path = "", Outcome = "";
    public long Total, Passed, Failed, Skipped, Other, RunErrors;
    public bool BadRun, Invalid;
    public double? Seconds;
}
internal sealed class ReportReader(Options o, bool includeFailureMessages = false)
{
    readonly string mode = o.Mode.ToLowerInvariant(), test = o.Get("Test");
    readonly int top = o.Top, maxChars = o.MaxChars, stackLines = o.StackLines;
    readonly DateTimeOffset? notBefore = o.NotBefore;
    readonly List<Dictionary<string, object?>> rows = [], errors = [];
    long matched, unranked, invalid;
    string Mode => mode;
    void Error(string report, string code)
    {
        invalid++;
        if (errors.Count < top)
        {
            errors.Add(new()
            {
                ["report"] = Output.Safe(report, maxChars),
                ["error"] = code
            });
        }
    }
    void Row(Dictionary<string, object?> row)
    {
        matched++;
        if (Mode == "slow")
        {
            int index = rows.FindIndex(r => Convert.ToDouble(r["seconds"]) < Convert.ToDouble(row["seconds"]));
            if (index < 0)
            {
                index = rows.Count;
            }

            if (index < top)
            {
                rows.Insert(index, row);
            }

            if (rows.Count > top)
            {
                rows.RemoveAt(top);
            }
        }
        else if (rows.Count < top)
        {
            rows.Add(row);
        }
    }
    public ReportResult Read()
    {
        var files = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        bool Add(string path)
        {
            if (notBefore is { } n && File.GetLastWriteTimeUtc(path) < n.UtcDateTime)
            {
                return false;
            }

            files.Add(System.IO.Path.GetFullPath(path));
            if (files.Count > o.MaxFiles)
            {
                throw new CliError("too_many_reports");
            }

            return true;
        }
        foreach (string entry in o.Array("Path"))
        {
            try
            {
                int candidates = 0, accepted = 0;
                if (Directory.Exists(entry))
                {
                    var enumeration = new EnumerationOptions { RecurseSubdirectories = o.Flag("Recurse"), IgnoreInaccessible = false, AttributesToSkip = FileAttributes.ReparsePoint, MatchCasing = MatchCasing.CaseInsensitive };
                    foreach (var path in Directory.EnumerateFiles(entry, "*.trx", enumeration))
                    {
                        candidates++;
                        if (Add(path))
                        {
                            accepted++;
                        }
                    }
                }
                else if (File.Exists(entry))
                {
                    if (!System.IO.Path.GetExtension(entry).Equals(".trx", StringComparison.OrdinalIgnoreCase))
                    {
                        Error(System.IO.Path.GetFileName(entry), "not_trx_path");
                        continue;
                    }
                    candidates++;
                    if (Add(entry))
                    {
                        accepted++;
                    }
                }
                else
                {
                    Error(System.IO.Path.GetFileName(entry), "path_unavailable");
                    continue;
                }
                if (candidates == 0)
                {
                    Error(System.IO.Path.GetFileName(entry), "no_reports");
                }
                else if (accepted == 0)
                {
                    Error(System.IO.Path.GetFileName(entry), "no_fresh_reports");
                }
            }
            catch (CliError) { throw; }
            catch { Error(System.IO.Path.GetFileName(entry), "path_unavailable"); }
        }
        // PowerShell Sort-Object FullName uses the current culture, not ordinal ordering.
        var reports = files.OrderBy(p => p, StringComparer.CurrentCultureIgnoreCase).Select(ReadFile).ToList();
        if (reports.Count == 0 && invalid == 0)
        {
            Error("", "no_reports");
        }

        if (Mode == "detail" && matched == 0 && invalid == 0)
        {
            Error("", "test_not_found");
        }

        int exit = reports.Any(r => r.BadRun || r.Failed > 0 || r.Other > 0 || o.Flag("FailOnSkipped") && r.Skipped > 0) ? 1 : 0;
        if (invalid > 0)
        {
            exit = 2;
        }

        var p = new Dictionary<string, object?> { ["status"] = exit == 2 ? "invalid" : exit == 1 ? "fail" : "pass", ["reports"] = reports.Count };
        if (Mode == "summary")
        {
            p["total"] = reports.Sum(r => r.Total);
            p["passed"] = reports.Sum(r => r.Passed);
            p["failed"] = reports.Sum(r => r.Failed);
            p["skipped"] = reports.Sum(r => r.Skipped);
            p["other"] = reports.Sum(r => r.Other);
            p["runErrors"] = reports.Sum(r => r.RunErrors);
            if (reports.Any(r => r.Seconds != null))
            {
                p["sumReportSeconds"] = Math.Round(reports.Sum(r => r.Seconds ?? 0), 3);
            }
        }
        else
        {
            if (Mode == "slow")
            {
                foreach (var row in rows)
                {
                    row["seconds"] = Math.Round(Convert.ToDouble(row["seconds"]), 3);
                }
            }

            p["matched"] = matched;
            p["omitted"] = matched - rows.Count;
            p["items"] = rows;
            if (unranked > 0)
            {
                p["unranked"] = unranked;
            }
        }
        if (invalid > 0)
        {
            p["invalid"] = invalid;
            p["errors"] = errors;
        }
        return new(p, exit, reports, rows);
    }
    static bool Is(string? s, params string[] values) => values.Contains(s, StringComparer.OrdinalIgnoreCase);
    static long Counter(XmlReader x, string key, bool optional = false)
    {
        var a = x.GetAttribute(key);
        if (optional && a == null)
        {
            return 0;
        }

        return long.TryParse(a, out var n) && n >= 0 ? n : throw new CliError("invalid_counters");
    }
    Report ReadFile(string path)
    {
        var r = new Report { Path = path };
        string file = Output.Safe(System.IO.Path.GetFileName(path), maxChars);
        bool summary = false, counters = false, start = false;
        long total = 0, passed = 0, failed = 0, skipped = 0, other = 0;
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (stream.Length > o.MaxFileBytes)
            {
                throw new CliError("file_too_large");
            }

            using var x = XmlReader.Create(stream, new()
            {
                DtdProcessing = DtdProcessing.Prohibit,
                XmlResolver = null,
                IgnoreComments = true,
                IgnoreProcessingInstructions = true,
                MaxCharactersInDocument = o.MaxFileBytes
            });
            x.MoveToContent();
            if (x.LocalName != "TestRun" || x.Depth != 0)
            {
                throw new CliError("not_trx");
            }

            string section = "";
            while (x.Read())
            {
                if (x.NodeType != XmlNodeType.Element)
                {
                    continue;
                }

                if (x.Depth == 1)
                {
                    section = x.LocalName;
                }

                if (section == "Times" && x.Depth == 1)
                {
                    if (DateTimeOffset.TryParse(x.GetAttribute("start"), out var a) && DateTimeOffset.TryParse(x.GetAttribute("finish"), out var b) && b >= a)
                    {
                        start = true;
                        r.Seconds = Math.Round((b - a).TotalSeconds, 3);
                        if (notBefore is { } n && a < n)
                        {
                            throw new CliError("stale_run");
                        }
                    }
                }
                else if (section == "Results" && x.LocalName == "UnitTestResult" && x.Depth == 2)
                {
                    string name = x.GetAttribute("testName") ?? "", outcome = x.GetAttribute("outcome") ?? "";
                    bool hasDuration = TimeSpan.TryParse(x.GetAttribute("duration"), CultureInfo.InvariantCulture, out var duration) && duration >= TimeSpan.Zero;
                    total++;
                    if (Is(outcome, "Passed"))
                    {
                        passed++;
                    }
                    else if (Is(outcome, "Failed", "Error", "Timeout", "Aborted"))
                    {
                        failed++;
                    }
                    else if (Is(outcome, "NotExecuted", "Skipped"))
                    {
                        skipped++;
                    }
                    else
                    {
                        other++;
                    }

                    bool matches = name.Contains(test, StringComparison.OrdinalIgnoreCase);
                    if (Mode == "slow" && matches && !hasDuration)
                    {
                        unranked++;
                    }

                    bool wanted = matches && (Mode == "detail" || Mode == "slow" && hasDuration || Mode == "failed" && Is(outcome, "Failed", "Error", "Timeout", "Aborted") || Mode == "skipped" && Is(outcome, "NotExecuted", "Skipped"));
                    bool retain = wanted && (rows.Count < top || Mode == "slow" && duration.TotalSeconds > Convert.ToDouble(rows[^1]["seconds"]));
                    Dictionary<string, object?>? row = null;
                    if (retain)
                    {
                        row = new()
                        {
                            ["report"] = file,
                            ["test"] = Output.Safe(name, maxChars)
                        };
                        if (Mode is "detail" or "slow" || !Is(outcome, "Failed", "NotExecuted", "Skipped"))
                        {
                            row["outcome"] = Output.Safe(outcome, maxChars);
                        }

                        if (name.Length > maxChars)
                        {
                            row["truncated"] = true;
                        }

                        if (Mode == "slow")
                        {
                            row["seconds"] = duration.TotalSeconds;
                        }
                    }
                    Details(x, row, retain && (Mode == "detail" || Mode == "failed" && includeFailureMessages));
                    if (wanted)
                    {
                        if (row != null)
                        {
                            Row(row);
                        }
                        else
                        {
                            matched++;
                        }
                    }
                }
                else if (section == "ResultSummary" && x.Depth == 1)
                {
                    if (summary)
                    {
                        throw new CliError("duplicate_summary");
                    }

                    summary = true;
                    r.Outcome = x.GetAttribute("outcome") ?? "";
                    if (!Is(r.Outcome, "Completed", "Passed"))
                    {
                        r.BadRun = true;
                        if (Mode == "runerrors")
                        {
                            Row(new()
                            {
                                ["report"] = file,
                                ["level"] = "outcome",
                                ["message"] = Output.Safe(r.Outcome, maxChars)
                            });
                        }
                    }
                }
                else if (section == "ResultSummary" && x.Depth == 2 && x.LocalName == "Counters")
                {
                    if (counters)
                    {
                        throw new CliError("duplicate_counters");
                    }

                    counters = true;
                    r.Total = Counter(x, "total");
                    r.Passed = Counter(x, "passed");
                    r.Failed = checked(Counter(x, "failed") + Counter(x, "error", true) + Counter(x, "timeout", true) + Counter(x, "aborted", true));
                    r.Skipped = Counter(x, "notExecuted");
                    r.Other = checked(r.Total - r.Passed - r.Failed - r.Skipped);
                    if (r.Other < 0)
                    {
                        throw new CliError("invalid_counters");
                    }
                }
                else if (section == "ResultSummary" && x.LocalName == "RunInfo")
                {
                    string level = x.GetAttribute("outcome") ?? "";
                    if (Is(level, "Error", "Failed", "Timeout", "Aborted"))
                    {
                        r.RunErrors++;
                        r.BadRun = true;
                    }
                    var text = Text(x);
                    if (Mode == "runerrors")
                    {
                        Row(new()
                        {
                            ["report"] = file,
                            ["level"] = Output.Safe(level, maxChars),
                            ["message"] = Output.Safe(text.Value, maxChars),
                            ["truncated"] = text.Cut || text.Value.Length > maxChars
                        });
                    }
                }
                else if (section == "ResultSummary" && x.LocalName == "ErrorInfo")
                {
                    r.RunErrors++;
                    r.BadRun = true;
                    using var sub = x.ReadSubtree();
                    while (sub.Read())
                    {
                        if (sub.NodeType == XmlNodeType.Element && sub.LocalName == "Message")
                        {
                            var text = Text(sub);
                            if (Mode == "runerrors")
                            {
                                Row(new()
                                {
                                    ["report"] = file,
                                    ["level"] = "error",
                                    ["message"] = Output.Safe(text.Value, maxChars),
                                    ["truncated"] = text.Cut || text.Value.Length > maxChars
                                });
                            }
                        }
                    }
                }
                else if (x.LocalName is "StdOut" or "StdErr" || x.Depth == 1 && section is not ("Times" or "Results" or "ResultSummary"))
                {
                    using var sub = x.ReadSubtree();
                }
            }
            if (!summary || !counters)
            {
                throw new CliError("missing_summary");
            }

            if (notBefore != null && !start)
            {
                throw new CliError("missing_run_time");
            }

            if (r.Total == 0)
            {
                throw new CliError("no_tests");
            }

            if (r.Total != total || r.Passed != passed || r.Failed != failed || r.Skipped != skipped || r.Other != other)
            {
                throw new CliError("counter_result_mismatch");
            }
        }
        catch (Exception e) { r.Invalid = true; Error(file, e is CliError ? e.Message : "unreadable_or_invalid_xml"); }
        return r;
    }
    void Details(XmlReader x, Dictionary<string, object?>? row, bool include)
    {
        using var sub = x.ReadSubtree();
        while (sub.Read())
        {
            if (sub.NodeType != XmlNodeType.Element)
            {
                continue;
            }

            if (sub.LocalName == "InnerResults" || sub.LocalName == "UnitTestResult" && sub.Depth > 0)
            {
                throw new CliError("unsupported_hierarchy");
            }

            if (sub.LocalName is "StdOut" or "StdErr" or "ResultFiles" or "CollectorDataEntries" || sub.LocalName == "ErrorInfo" && !include)
            {
                using var skip = sub.ReadSubtree();
            }
            else if (sub.Depth == 3 && include && (sub.LocalName == "Message" || sub.LocalName == "StackTrace" && stackLines > 0))
            {
                bool stack = sub.LocalName == "StackTrace";
                var text = Text(sub);
                string[] lines = text.Value.Split('\n').Where(l => !string.IsNullOrWhiteSpace(l)).ToArray();
                string value = stack ? string.Join(" | ", lines.Take(stackLines)) : text.Value;
                string safe = Output.Safe(value, maxChars);
                if (safe != "")
                {
                    row![stack ? "stack" : "message"] = safe;
                }

                if (text.Cut || value.Length > maxChars || stack && lines.Length > stackLines)
                {
                    row!["truncated"] = true;
                }
            }
        }
    }
    (string Value, bool Cut) Text(XmlReader x)
    {
        using var sub = x.ReadSubtree();
        int max = Math.Max(8192, maxChars * 4);
        var b = new StringBuilder();
        char[] buffer = new char[256];
        bool cut = false;
        while (sub.Read())
        {
            if (sub.NodeType is not (XmlNodeType.Text or XmlNodeType.CDATA or XmlNodeType.Whitespace or XmlNodeType.SignificantWhitespace))
            {
                continue;
            }

            int n;
            while ((n = sub.ReadValueChunk(buffer, 0, buffer.Length)) > 0)
            {
                int take = Math.Min(n, max - b.Length);
                if (take > 0)
                {
                    b.Append(buffer, 0, take);
                }

                if (take < n)
                {
                    cut = true;
                    break;
                }
            }
            if (cut)
            {
                break;
            }
        }
        return (b.ToString(), cut);
    }
}
