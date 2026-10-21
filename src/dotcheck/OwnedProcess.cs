using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Dotcheck;

// The worker cannot launch native code before the parent assigns it to a kill-on-close job.
// If the owner dies before assignment, stdin closes and the worker exits without spawning.
internal sealed partial class OwnedProcess : IDisposable
{
    const uint KillOnJobClose = 0x2000;
    const int ExtendedLimitInformation = 9;
    const int BasicAccountingInformation = 1;
    readonly SafeFileHandle job;
    public Process Process
    {
        get;
    }
    public OwnedProcess(ProcessStartInfo native)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new CliError("runner_windows_only");
        }

        job = CreateJobObject(IntPtr.Zero, null);
        if (job.IsInvalid)
        {
            job.Dispose();
            throw new CliError("owned_job_creation_failed");
        }
        var info = new ExtendedLimit { Basic = new BasicLimit { Flags = KillOnJobClose } };
        if (!SetInformationJobObject(job, ExtendedLimitInformation, ref info, (uint)Marshal.SizeOf<ExtendedLimit>()))
        {
            job.Dispose();
            throw new CliError("owned_job_creation_failed");
        }
        Process = new Process();
        try
        {
            var psi = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = native.WorkingDirectory };
            // Also supports invoking the framework-dependent DLL through dotnet.
            if (string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "dotnet", StringComparison.OrdinalIgnoreCase))
            {
                psi.ArgumentList.Add(Path.Combine(AppContext.BaseDirectory, "dotcheck.dll"));
            }

            psi.ArgumentList.Add("--internal-worker");
            psi.ArgumentList.Add(native.FileName);
            foreach (var a in native.ArgumentList)
            {
                psi.ArgumentList.Add(a);
            }

            foreach (var kv in native.Environment)
            {
                psi.Environment[kv.Key] = kv.Value;
            }

            Process.StartInfo = psi;
            if (!Process.Start())
            {
                throw new CliError("cannot_run_dotnet");
            }

            if (!AssignProcessToJobObject(job, Process.SafeHandle))
            {
                throw new CliError("owned_job_assignment_failed");
            }

            Process.StandardInput.WriteLine("go");
            Process.StandardInput.Flush();
            Process.StandardInput.Close();
        }
        catch
        {
            try
            {
                Process.StandardInput.Close();
                if (!Process.WaitForExit(1000))
                {
                    Process.Kill();
                    Process.WaitForExit(1000);
                }
            }
            catch { }
            Process.Dispose();
            job.Dispose();
            throw;
        }
    }
    public bool StopAndWait()
    {
        if (!TerminateJobObject(job, 1))
        {
            return false;
        }

        var timer = Stopwatch.StartNew();
        do
        {
            if (!QueryInformationJobObject(job, BasicAccountingInformation, out Accounting data, (uint)Marshal.SizeOf<Accounting>(), IntPtr.Zero))
            {
                return false;
            }

            if (data.ActiveProcesses == 0)
            {
                return true;
            }

            Thread.Sleep(10);
        } while (timer.ElapsedMilliseconds < 5000);
        return false;
    }
    public void Dispose()
    {
        job.Dispose();
        Process.Dispose();
    }
    public static int Worker(string[] args)
    {
        try
        {
            // A bounded handshake also prevents an accidentally invoked worker from staying alive.
            var handshake = Console.In.ReadLineAsync();
            if (!handshake.Wait(10000) || handshake.Result != "go" || args.Length == 0)
            {
                return 2;
            }

            var psi = new ProcessStartInfo(args[0]) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true };
            foreach (var a in args[1..])
            {
                psi.ArgumentList.Add(a);
            }

            using var child = Process.Start(psi)!;
            child.StandardInput.Close();
            child.WaitForExit();
            return child.ExitCode;
        }
        catch { return 2; }
    }
    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimit
    {
        public long ProcessTime, JobTime; public uint Flags; public nuint MinimumWorkingSet, MaximumWorkingSet; public uint ActiveLimit; public nuint Affinity; public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters
    {
        public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimit
    {
        public BasicLimit Basic; public IoCounters Io; public nuint ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct Accounting
    {
        public long UserTime, KernelTime, PeriodUser, PeriodKernel; public uint PageFaults, TotalProcesses, ActiveProcesses, TerminatedProcesses;
    }
    [LibraryImport("kernel32.dll", EntryPoint = "CreateJobObjectW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    private static partial SafeFileHandle CreateJobObject(IntPtr attributes, string? name);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetInformationJobObject(SafeFileHandle job, int infoClass, ref ExtendedLimit info, uint length);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AssignProcessToJobObject(SafeFileHandle job, SafeProcessHandle process);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool TerminateJobObject(SafeFileHandle job, uint exit);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool QueryInformationJobObject(SafeFileHandle job, int infoClass, out Accounting data, uint length, IntPtr returned);
}
