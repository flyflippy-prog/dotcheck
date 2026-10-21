using Dotcheck;
using System.Text.Json;

string root = Path.Combine(Path.GetTempPath(), "dotcheck-behavior-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
string fixture = Path.GetFullPath(args.Length > 0 ? args[0] : "tests/fixtures");
int checks = 0;
void Check(bool condition, string name) { if (!condition) { throw new Exception("FAIL " + name); } checks++; }
void Invalid(string code, Action action, string name)
{
    try
    {
        action();
        throw new Exception("Expected rejection " + name);
    }
    catch (CliError e) { Check(e.Message == code, name); }
}
Options Opt(params string[] a) { var o = Options.Parse(a); o.Validate(); return o; }
ReportResult Read(string file, params string[] extra) => new ReportReader(Opt(new[] { "-Path", Path.Combine(fixture, file) }.Concat(extra).ToArray())).Read();
foreach (var (file, exit) in new[] { ("passed.trx", 0), ("failed.trx", 1), ("skipped.trx", 0), ("aborted.trx", 1), ("mismatch.trx", 2), ("hierarchy.trx", 2), ("xxe.trx", 2), ("empty.trx", 2) })
{
    Check(Read(file).Exit == exit, file);
}

Check(Read("skipped.trx", "-FailOnSkipped").Exit == 1, "skip policy");
foreach (string mode in new[] { "Failed", "Skipped", "Slow", "Detail", "RunErrors" })
{
    var result = Read("failed.trx", "-Mode", mode, "-Test", mode == "RunErrors" ? "" : "Synthetic");
    Check(result.Exit == 1, "filter cannot clear health " + mode);
    string json = Output.Json(result.Payload);
    Check(!json.Contains("synthetic-secret") && !json.Contains("private-stdout") && !json.Contains("private-stderr"), "private diagnostics " + mode);
}
Check(Read("passed.trx", "-NotBefore", "2099-01-01T00:00:00Z").Exit == 2, "freshness");
Check(Read("skipped.trx", "-Mode", "Slow").Payload.ContainsKey("unranked"), "unranked duration");
Check(Read("passed.trx", "-Mode", "Detail", "-Test", "absent").Exit == 2, "no detail match");
Invalid("invalid_arguments", () => Opt("-Path", "x", "-Top", "0"), "top min");
Invalid("invalid_arguments", () => Opt("-Path", "x", "-MaxChars", "4500"), "max chars");
Invalid("invalid_arguments", () => Opt("-Path", "x", "-StackLines", "2"), "stack opt in");
Invalid("invalid_arguments", () => Opt("-Build", "-Run"), "actions conflict");
Invalid("invalid_arguments", () => Opt("-LastRun", "-JournalPath", "x", "-NoRestore"), "inspection inert");
Invalid("invalid_arguments", () => Opt("-Path", "x", "-Mode", "Detail"), "detail needs filter");
Check(Opt("--p", "a", "b", "-Json:$false").Array("Path").Length == 2, "native array and switch false");
Check(!Opt("-Path", "a", "-Json:false").Flag("Json"), "false switch");
Check(Options.WantsJson(["--Json:$true", "-invalid"]) && !Options.WantsJson(["-Json", "-Json:false"]), "JSON parse error envelope");
Check(Opt("-Path", "a", "-NotBefore", "2026-10-20T14:00:00+02:00").NotBefore!.Value.UtcDateTime.Hour == 12, "timezone");
string many = Path.Combine(root, "many");
Directory.CreateDirectory(many);
File.Copy(Path.Combine(fixture, "passed.trx"), Path.Combine(many, "a.trx"));
File.Copy(Path.Combine(fixture, "passed.trx"), Path.Combine(many, "b.trx"));
Invalid("too_many_reports", () => new ReportReader(Opt("-Path", many, "-MaxFiles", "1")).Read(), "file limit");
Directory.CreateDirectory(Path.Combine(many, "nested"));
File.Copy(Path.Combine(fixture, "passed.trx"), Path.Combine(many, "nested/c.trx"));
Check(new ReportReader(Opt("-Path", many)).Read().Reports.Count == 2, "nonrecursive");
Check(new ReportReader(Opt("-Path", many, "-Recurse")).Read().Reports.Count == 3, "recursive");
string large = Path.Combine(root, "large.trx");
File.WriteAllText(large, new string('x', 1048577));
Check(new ReportReader(Opt("-Path", large, "-MaxFileMiB", "1")).Read().Exit == 2, "size bound");
string duplicate = Path.Combine(root, "duplicate.trx");
File.WriteAllText(duplicate, File.ReadAllText(Path.Combine(fixture, "passed.trx")).Replace("</TestRun>", "<ResultSummary outcome='Completed'/></TestRun>"));
Check(new ReportReader(Opt("-Path", duplicate)).Read().Exit == 2, "duplicate summary");
Check(Output.Safe("password=abc Bearer XYZ https://a:b@example.test/path?q=secret").Contains("[redacted]") && !Output.Safe("password=abc").Contains("abc"), "redaction");
Check(Output.Safe(new string('x', 40000) + "password=synthetic-private") == "[diagnostic omitted: oversized input]", "oversized diagnostics are omitted without exposing a prefix");
var jsonPayload = new Dictionary<string, object?>
{
    ["null"] = null,
    ["signed"] = -7,
    ["count"] = 123L,
    ["seconds"] = 1.25,
    ["tree"] = false,
    ["reports"] = new[] { "Unicode отчёт.trx" },
    ["items"] = new List<Dictionary<string, object?>> { new() { ["message"] = "safe" } }
};
using (var generatedJson = JsonDocument.Parse(Output.Json(jsonPayload)))
{
    Check(generatedJson.RootElement.GetProperty("null").ValueKind == JsonValueKind.Null &&
        generatedJson.RootElement.GetProperty("signed").GetInt32() == -7 &&
        !generatedJson.RootElement.GetProperty("tree").GetBoolean() &&
        generatedJson.RootElement.GetProperty("reports")[0].GetString() == "Unicode отчёт.trx", "source-generated JSON preserves value types and nulls");
}
var capture = new NativeCapture(Opt("-Build", "-MaxFiles", "1"), null);
using (var nativeText = new StreamReader(new MemoryStream(System.Text.Encoding.UTF8.GetBytes(
    "Results File: same.trx\nResults File: same.trx\nfile.cs: warning CS0001: repeated\nfile.cs: warning CS0001: repeated\n"))))
{
    capture.Read(nativeText, CancellationToken.None).GetAwaiter().GetResult();
}
Check(!capture.Limit && capture.Reports.Count == 1 && capture.WarningCount == 1, "duplicate report announcements and diagnostics do not consume distinct limits");

string ranked = Path.Combine(root, "ranked.trx");
File.WriteAllText(ranked, "<TestRun><Results>" + string.Concat(new[] { 1, 4, 4, 2, 3 }.Select((seconds, index) =>
    $"<UnitTestResult testName='Rank{index}' outcome='Passed' duration='00:00:0{seconds}'/>")) +
    "</Results><ResultSummary outcome='Completed'><Counters total='5' passed='5' failed='0' notExecuted='0'/></ResultSummary></TestRun>");
var ranking = new ReportReader(Opt("-Path", ranked, "-Mode", "Slow", "-Top", "2")).Read();
Check(ranking.Exit == 0 && (long)ranking.Payload["matched"]! == 5 && (long)ranking.Payload["omitted"]! == 3 &&
    ranking.Items.Select(item => (string)item["test"]!).SequenceEqual(new[] { "Rank1", "Rank2" }), "slow ranking retains stable ties and counts omitted rows");
Check(new RegistrationEnvironment().Owned(Path.GetFullPath("src/dotcheck/bin/Release/net10.0/dotcheck.exe")), "native ownership metadata");
foreach (var (key, min, max) in new[] { ("Top", 1, 100), ("MaxChars", 32, 4096), ("StackLines", 0, 20), ("MaxFiles", 1, 10000), ("MaxFileMiB", 1, 1024), ("MaxLogMiB", 1, 1024), ("TimeoutSeconds", 1, 86400), ("HeartbeatSeconds", 0, 86400), ("KeepReports", 0, 10000) })
{
    var options = Options.Parse(["-" + key, min.ToString()]);
    Check(options.Number(key, 99, min, max) == min, key + " minimum");
    options = Options.Parse(["-" + key, max.ToString()]);
    Check(options.Number(key, 99, min, max) == max, key + " maximum");
    Invalid("invalid_arguments", () => Options.Parse(["-" + key, (min - 1).ToString()]).Number(key, 99, min, max), key + " below range");
    Invalid("invalid_arguments", () => Options.Parse(["-" + key, (max + 1).ToString()]).Number(key, 99, min, max), key + " above range");
}
string modified = Path.Combine(root, "modified.trx");
string valid = File.ReadAllText(Path.Combine(fixture, "passed.trx"));
foreach (var (text, expected, name) in new[] {
    (valid.Replace("<Counters", "<Counters total='-1' unused='x'/><Counters"), 2, "malformed counters"),
    (valid.Replace("<Counters", "<Counters total='1' passed='1' failed='0' notExecuted='0'/><Counters"), 2, "duplicate counters"),
    (valid.Replace("<Counters total=\"1\" passed=\"1\" failed=\"0\" notExecuted=\"0\"/>", ""), 2, "missing counters"),
    (valid.Replace("</ResultSummary>", "<Output><ErrorInfo><Message>token=synthetic-run-secret Host failure</Message></ErrorInfo></Output></ResultSummary>"), 1, "run ErrorInfo"),
    (valid.Replace("outcome=\"Passed\"", "outcome=\"FutureOutcome\"").Replace("passed=\"1\"", "passed=\"0\""), 1, "unknown leaf fails"),
    (valid.Replace("outcome=\"Passed\"", "outcome=\"Timeout\"").Replace("passed=\"1\" failed=\"0\"", "passed=\"0\" failed=\"0\" timeout=\"1\""), 1, "timeout counter"),
    (valid.Replace("</UnitTestResult>", "</UnitTestResult>") + "<trailing>", 2, "trailing malformed XML") })
{
    File.WriteAllText(modified, text);
    var result = new ReportReader(Opt("-Path", modified, "-Mode", "RunErrors")).Read();
    Check(result.Exit == expected && !Output.Json(result.Payload).Contains("synthetic-run-secret"), name);
}
var aggregate = new ReportReader(Opt("-Path", Path.Combine(fixture, "passed.trx"), Path.Combine(fixture, "failed.trx"))).Read();
Check(Convert.ToInt64(aggregate.Payload["total"]) == 2 && Convert.ToDouble(aggregate.Payload["sumReportSeconds"]) == 2 && aggregate.Exit == 1, "attempt aggregation and summed report wall time");

string journal = Path.Combine(root, "j.jsonl");
string id = Guid.NewGuid().ToString("D");
void WriteJournal(object start, object finish) => File.WriteAllText(journal, JsonSerializer.Serialize(start) + "\n" + JsonSerializer.Serialize(finish) + "\n");
var startEntry = new { schemaVersion = 1, @event = "started", runId = id, startedUtc = "2026-10-19T00:00:00Z", verb = "test" };
var saved = new Dictionary<string, object?> { ["exit"] = -7, ["status"] = "fail", ["outcome"] = "tests_failed", ["reports"] = new[] { Path.Combine(fixture, "passed.trx") } };
WriteJournal(startEntry, new { schemaVersion = 1, @event = "finished", runId = id, startedUtc = startEntry.startedUtc, result = saved });
Check(Journal.Inspect(Opt("-LastRun", "-JournalPath", journal)).Item2 == -7, "historical signed failure");
saved["exit"] = 0;
saved["status"] = "pass";
saved["outcome"] = "passed";
saved["reports"] = new[] { Path.Combine(fixture, "failed.trx") };
WriteJournal(startEntry, new { @event = "finished", runId = id, startedUtc = startEntry.startedUtc, result = saved });
Check(Journal.Inspect(Opt("-LastRun", "-JournalPath", journal)).Item2 == 1, "revalidation failure");
saved["outcome"] = "aborted";
WriteJournal(startEntry, new { @event = "finished", runId = id, startedUtc = startEntry.startedUtc, result = saved });
Invalid("invalid_journal", () => Journal.Inspect(Opt("-LastRun", "-JournalPath", journal)), "contradictory PASS outcome");
saved["outcome"] = "passed";
saved["nativeExit"] = -7;
WriteJournal(startEntry, new { @event = "finished", runId = id, startedUtc = startEntry.startedUtc, result = saved });
Invalid("invalid_journal", () => Journal.Inspect(Opt("-LastRun", "-JournalPath", journal)), "contradictory PASS native exit");
saved["nativeExit"] = 0;
saved["errorDiagnostics"] = 1;
WriteJournal(startEntry, new { @event = "finished", runId = id, startedUtc = startEntry.startedUtc, result = saved });
Invalid("invalid_journal", () => Journal.Inspect(Opt("-LastRun", "-JournalPath", journal)), "contradictory PASS compiler errors");
saved["errorDiagnostics"] = 0;
saved["total"] = 10;
saved["passed"] = 1;
saved["failed"] = 0;
saved["skipped"] = 0;
saved["other"] = 0;
WriteJournal(startEntry, new { @event = "finished", runId = id, startedUtc = startEntry.startedUtc, result = saved });
Invalid("invalid_journal", () => Journal.Inspect(Opt("-LastRun", "-JournalPath", journal)), "inconsistent saved counters");
saved["total"] = 1;
saved["reports"] = new[] { Path.Combine(fixture, "passed.trx") };
WriteJournal(startEntry, new { @event = "finished", runId = id, startedUtc = startEntry.startedUtc, result = saved });
Check(Journal.Inspect(Opt("-LastRun", "-JournalPath", journal)).Item2 == 0, "consistent saved counters remain readable");
File.AppendAllText(journal, "{\"event\":\"started\",\"event\":\"started\",\"startedUtc\":\"2026-10-20T00:00:00Z\"}\n");
Invalid("invalid_journal", () => Journal.Inspect(Opt("-LastRun", "-JournalPath", journal)), "duplicate JSON keys");

string clean = Path.Combine(root, "clean");
Directory.CreateDirectory(clean);
File.WriteAllText(Path.Combine(clean, "a.trx"), "owned");
File.WriteAllText(Path.Combine(clean, "b.trx"), "owned");
File.WriteAllText(Path.Combine(clean, "retain.log"), "retain");
Directory.CreateDirectory(Path.Combine(clean, "attachments"));
File.WriteAllText(Path.Combine(clean, "attachments/retain.trx"), "retain");
using (var locked = new FileStream(Path.Combine(clean, "a.trx"), FileMode.Open, FileAccess.ReadWrite, FileShare.None))
{
    var result = Setup.Clean(Opt("-Clean", "-ResultsDirectory", clean, "-KeepReports", "0"));
    Check(result.Item2 == 1 && (int)result.Item1["deleted"]! == 1, "cleanup locked file");
}
Check(File.Exists(Path.Combine(clean, "retain.log")) && File.Exists(Path.Combine(clean, "attachments/retain.trx")), "cleanup scope");
Check(Setup.Clean(Opt("-Clean", "-ResultsDirectory", clean, "-KeepReports", "0")).Item2 == 0 && !File.Exists(Path.Combine(clean, "a.trx")), "cleanup zero retention");

string current = Path.GetFullPath(Path.Combine(root, "new/dotcheck.exe")), previous = Path.GetFullPath(Path.Combine(root, "old/dotcheck.exe"));
var env = new FakeEnvironment();
env.OwnedFiles.UnionWith([current, previous]);
env.Set("PATH", Path.GetDirectoryName(previous) + ";C:\\foreign", EnvironmentVariableTarget.User);
env.Set("DOTCHECK_TOOL_FILE", previous, EnvironmentVariableTarget.User);
env.Set("PATH", "C:\\foreign", EnvironmentVariableTarget.Process);
var original = new Dictionary<(string, EnvironmentVariableTarget), string?>(env.Values);
Setup.Register(Opt("-Install"), env, current);
Check(env.Get("PATH", EnvironmentVariableTarget.User) == Path.GetDirectoryName(current) + ";C:\\foreign", "install repair");
Check(Setup.Register(Opt("-Install"), env, current).Item1["changed"] is false, "install idempotence");
Setup.Register(Opt("-Uninstall"), env, current);
Check(env.Get("PATH", EnvironmentVariableTarget.User) == "C:\\foreign" && env.Get("DOTCHECK_TOOL_FILE", EnvironmentVariableTarget.User) == null, "uninstall scope");
env.Values.Clear();
foreach (var p in original)
{
    env.Values[p.Key] = p.Value;
}

env.FailOnce = ("PATH", EnvironmentVariableTarget.User);
Invalid("path_install_failed", () => Setup.Register(Opt("-Install"), env, current), "transaction rollback");
Check(original.All(p => env.Get(p.Key.Item1, p.Key.Item2) == p.Value) && env.Get("DOTCHECK_TOOL_FILE", EnvironmentVariableTarget.Process) == null, "rollback state");
env.Set("DOTCHECK_TOOL_FILE", "C:\\foreign\\dotcheck.exe", EnvironmentVariableTarget.User);
Setup.Register(Opt("-Uninstall"), env, current);
Check(env.Get("DOTCHECK_TOOL_FILE", EnvironmentVariableTarget.User) == "C:\\foreign\\dotcheck.exe", "foreign registration preserved");

Console.WriteLine($"PASS checks={checks} evidence={root}");
File.WriteAllText(Path.Combine(root, "result.json"), JsonSerializer.Serialize(new { checks, status = "passed", utc = DateTimeOffset.UtcNow }));
return 0;

sealed class FakeEnvironment : IRegistrationEnvironment
{
    public readonly Dictionary<(string, EnvironmentVariableTarget), string?> Values = new();
    public readonly HashSet<string> OwnedFiles = new(StringComparer.OrdinalIgnoreCase);
    public (string, EnvironmentVariableTarget)? FailOnce;
    public string? Get(string n, EnvironmentVariableTarget t) => Values.GetValueOrDefault((n, t));
    public void Set(string n, string? v, EnvironmentVariableTarget t)
    {
        if (FailOnce == (n, t))
        {
            FailOnce = null;
            throw new IOException("synthetic failure");
        }
        Values[(n, t)] = v;
    }
    public bool Owned(string path) => OwnedFiles.Contains(path);
}
