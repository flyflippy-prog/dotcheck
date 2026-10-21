using System.Diagnostics;

string mode = Environment.GetEnvironmentVariable("DOTCHECK_SIM_CASE") ?? "quick";
string pidFile = Environment.GetEnvironmentVariable("DOTCHECK_SIM_PIDFILE") ?? "";
void Save(string file, string text) { File.WriteAllText(file + ".tmp", text); File.Move(file + ".tmp", file, true); }
if (args.Contains("--leaf")) { Thread.Sleep(120000); return 0; }
if (args.Contains("--grandchild"))
{
    using var child = Process.Start(new ProcessStartInfo(Environment.ProcessPath!, "--leaf") { UseShellExecute = false, CreateNoWindow = true })!;
    Save(pidFile + ".leaf", child.Id.ToString());
    Thread.Sleep(120000); return 0;
}
if (mode is "early" or "parentkill" or "pipes" or "delayed")
{
    if (mode == "delayed") Thread.Sleep(300);
    using var child = Process.Start(new ProcessStartInfo(Environment.ProcessPath!, "--grandchild") { UseShellExecute = false, CreateNoWindow = true })!;
    Save(pidFile, $"{Environment.ProcessId},{child.Id}");
    if (mode == "pipes") { var sw = Stopwatch.StartNew(); while (!File.Exists(pidFile + ".leaf") && sw.ElapsedMilliseconds < 5000) Thread.Sleep(10); return 0; }
    Thread.Sleep(120000); return 0;
}
if (mode == "flood")
{
    var a = Task.Run(() => { for (int i = 0; i < 20000; i++) Console.Out.Write(new string('a', 4096)); });
    var b = Task.Run(() => { for (int i = 0; i < 20000; i++) Console.Error.Write(new string('b', 4096)); });
    Task.WaitAll(a, b); return 0;
}
if (mode == "longline") { Console.Write(new string('x', 500000) + " password=synthetic-private\n"); return 0; }
if (mode == "diagnosticflood")
{
    for (int i = 0; i < 70000; i++) Console.WriteLine($"file.cs: warning CS0001: distinct diagnostic {i}");
    return 0;
}
if (mode == "signed") return -7;
if (mode == "warning") { Console.WriteLine("file.cs(1,2): warning CS0001: password=synthetic-private warning"); return 0; }
if (mode == "compilerzero") { Console.WriteLine("file.cs(1,2): error CS0001: synthetic compiler failure with zero exit"); return 0; }
if (mode == "argv") { File.WriteAllText(pidFile + ".args", System.Text.Json.JsonSerializer.Serialize(args)); return 0; }
if (mode == "missing") return 0;
if (mode is "stale" or "invalid" or "trxpass" or "nonzero" or "skip")
{
    string? directory = null; int index = Array.IndexOf(args, "--results-directory"); if (index >= 0) directory = args[index + 1];
    directory ??= Path.Combine(Environment.CurrentDirectory, "TestResults"); Directory.CreateDirectory(directory);
    string path = Path.Combine(directory, Guid.NewGuid() + ".trx");
    string time = (mode == "stale" ? DateTimeOffset.UtcNow.AddDays(-1) : DateTimeOffset.UtcNow).ToString("o");
    File.WriteAllText(path, mode == "invalid" ? "<broken>" : $"<TestRun><Times start='{time}' finish='{time}'/><Results><UnitTestResult testName='Synthetic.Native' outcome='{(mode == "skip" ? "NotExecuted" : "Passed")}'/></Results><ResultSummary outcome='Completed'><Counters total='1' passed='{(mode == "skip" ? 0 : 1)}' failed='0' notExecuted='{(mode == "skip" ? 1 : 0)}'/></ResultSummary></TestRun>");
    Console.WriteLine("Results File: " + path); return mode == "nonzero" ? 7 : 0;
}
return 0;
