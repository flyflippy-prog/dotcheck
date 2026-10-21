using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;

string tool = Path.GetFullPath(args[0]), simulator = Path.GetFullPath(args[1]), project = Path.GetFullPath(args[2]);
string root = Path.Combine(Path.GetTempPath(), "dotcheck-cancel-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
string pidFile = Path.Combine(root, "native.pid"), journal = Path.Combine(root, "journal.jsonl");
Environment.SetEnvironmentVariable("PATH", Path.GetDirectoryName(simulator) + ";" + Environment.GetEnvironmentVariable("PATH"));
Environment.SetEnvironmentVariable("DOTCHECK_SIM_CASE", "early"); Environment.SetEnvironmentVariable("DOTCHECK_SIM_PIDFILE", pidFile);
var startup = new Native.Startup { Size = Marshal.SizeOf<Native.Startup>(), Flags = 1, Show = 0 };
Native.ProcessInfo process = default; int code = 1;
try
{
    // Only the test supervisor uses CreateProcess to request a separate hidden console.
    // The product always passes native arguments with ProcessStartInfo.ArgumentList.
    string Quote(string s) => "\"" + s.Replace("\"", "\\\"") + "\"";
    string command = string.Join(' ', new[] { tool, "-Build", "-Project", project, "-Json", "-JournalPath", journal, "-Reason", "synthetic cancellation gate" }.Select(Quote));
    if (!Native.CreateProcess(tool, command, IntPtr.Zero, IntPtr.Zero, false, 0x10, IntPtr.Zero, null, ref startup, out process)) throw new Exception("hidden console spawn failed");
    var sw = Stopwatch.StartNew(); while (!File.Exists(pidFile + ".leaf") && sw.ElapsedMilliseconds < 10000) Thread.Sleep(20);
    if (!File.Exists(pidFile + ".leaf")) throw new Exception("native descendants did not start");
    Native.FreeConsole();
    if (!Native.AttachConsole(process.Id)) throw new Exception("console attach failed");
    if (!Native.SetConsoleCtrlHandler(null, true)) throw new Exception("supervisor control suppression failed");
    if (!Native.GenerateConsoleCtrlEvent(0, 0)) throw new Exception("CTRL_C dispatch failed");
    if (Native.WaitForSingleObject(process.Handle, 10000) != 0) throw new Exception("cancellation timeout");
    Native.FreeConsole();
    var finish = File.ReadLines(journal).Select(s => JsonNode.Parse(s)!).Last(n => n["event"]!.ToString() == "finished");
    var result = finish["result"]!;
    if (result["exit"]!.GetValue<int>() != 130 || result["condition"]!.ToString() != "cancelled" || result["processTreeCompleted"]!.GetValue<bool>() != true) throw new Exception("unconfirmed cancellation result");
    int[] ids = File.ReadAllText(pidFile).Split(',').Select(int.Parse).Append(int.Parse(File.ReadAllText(pidFile + ".leaf"))).ToArray();
    foreach (int id in ids)
    {
        try { using var p = Process.GetProcessById(id); if (!p.HasExited) throw new Exception("owned descendant survived"); }
        catch (ArgumentException) { }
    }
    File.WriteAllText(Path.Combine(root, "result.txt"), "PASS cancellationChecks=2 real CTRL_C_EVENT; confirmed job completion and no descendants");
    code = 0;
}
catch (Exception e) { File.WriteAllText(Path.Combine(root, "result.txt"), "FAIL " + e.Message); }
finally
{
    Native.FreeConsole();
    if (process.Handle != IntPtr.Zero) { if (Native.WaitForSingleObject(process.Handle, 0) != 0) Native.TerminateProcess(process.Handle, 1); Native.CloseHandle(process.Handle); Native.CloseHandle(process.Thread); }
}
// Preserve redirected host output by writing through its original standard stream where possible.
try { Console.WriteLine($"{(code == 0 ? "PASS" : "FAIL")} cancellation evidence={root}"); } catch { }
File.WriteAllText(args.Length > 3 ? args[3] : "evidence/cancellation.txt", $"{(code == 0 ? "PASS" : "FAIL")} evidence={root}\n" + File.ReadAllText(Path.Combine(root, "result.txt")));
return code;

internal static class Native
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct Startup { public int Size; public string? Reserved, Desktop, Title; public uint X, Y, Width, Height, XChars, YChars, Fill, Flags; public short Show, ReservedCount; public IntPtr ReservedPtr, In, Out, Err; }
    [StructLayout(LayoutKind.Sequential)] internal struct ProcessInfo { public IntPtr Handle, Thread; public uint Id, ThreadId; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CreateProcess(string application, string command, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string? directory, ref Startup startup, out ProcessInfo process);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool AttachConsole(uint id);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool FreeConsole();
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    internal static bool SetConsoleCtrlHandler(object? _, bool add) => SetConsoleCtrlHandler(IntPtr.Zero, add);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GenerateConsoleCtrlEvent(uint ev, uint group);
    [DllImport("kernel32.dll")] internal static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool TerminateProcess(IntPtr handle, uint exit);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CloseHandle(IntPtr handle);
}
