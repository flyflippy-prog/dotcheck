using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace Dotcheck;

internal sealed partial class NativeCapture(Options o, StreamWriter? log)
{
    internal const int MaxDistinctDiagnostics = 65536;
    readonly long maxBytes = o.MaxLogBytes;
    readonly int top = o.Top, maxChars = o.MaxChars, maxFiles = o.MaxFiles;
    readonly object sync = new();
    readonly HashSet<DiagnosticKey> seen = [];
    public readonly List<Dictionary<string, object?>> Errors = [], Warnings = [];
    public readonly Queue<string> Tail = new();
    public readonly HashSet<string> Reports = new(StringComparer.OrdinalIgnoreCase);
    public int ErrorCount, WarningCount;
    long bytes;
    public volatile bool Limit;
    public volatile bool Failed;
    public string LimitCondition { get; private set; } = "log_limit";

    // Full SHA-256 keys avoid retaining secret-bearing raw diagnostic strings.
    // Fixed-width values and a hard cardinality limit bound deduplication memory.
    readonly record struct DiagnosticKey(ulong A, ulong B, ulong C, ulong D);

    void SetLimit(string condition)
    {
        if (Limit)
        {
            return;
        }

        LimitCondition = condition;
        Limit = true;
    }
    public Task Read(StreamReader reader, CancellationToken token) => Task.Run(async () =>
    {
        char[] buffer = new char[4096];
        var line = new StringBuilder();
        bool clipped = false;
        try
        {
            int n;
            while ((n = await reader.ReadAsync(buffer.AsMemory(), token)) > 0)
            {
                lock (sync)
                {
                    // UTF8 worst case per UTF16 code unit bounds both captured streams even for split surrogates.
                    bytes += Encoding.UTF8.GetByteCount(buffer, 0, n);
                    if (bytes > maxBytes)
                    {
                        SetLimit("log_limit");
                        return;
                    }
                    log?.Write(buffer, 0, n);
                    for (int i = 0; i < n; i++)
                    {
                        if (buffer[i] == '\n')
                        {
                            Line(line.ToString(), clipped);
                            if (Limit)
                            {
                                return;
                            }

                            line.Clear();
                            clipped = false;
                        }
                        else if (line.Length < 8192)
                        {
                            line.Append(buffer[i]);
                        }
                        else
                        {
                            clipped = true;
                        }
                    }
                }
            }
            lock (sync)
            {
                if (line.Length > 0)
                {
                    Line(line.ToString(), clipped);
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch { Failed = true; }
    });
    void Line(string line, bool clipped)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return;
        }

        if (!clipped && line.TrimStart().StartsWith("Results File:", StringComparison.Ordinal) && line.TrimEnd().EndsWith(".trx", StringComparison.OrdinalIgnoreCase))
        {
            string path = line[(line.IndexOf(':') + 1)..].Trim();
            if (!Reports.Contains(path) && Reports.Count >= maxFiles)
            {
                SetLimit("log_limit");
                return;
            }
            Reports.Add(path);
        }
        // A truncated raw line may cut a credential key in half. Never emit that prefix.
        if (clipped)
        {
            Tail.Enqueue("[native line omitted: exceeds 8192 characters]");
            if (Tail.Count > top)
            {
                Tail.Dequeue();
            }

            return;
        }
        Tail.Enqueue(Output.Safe(line, maxChars));
        if (Tail.Count > top)
        {
            Tail.Dequeue();
        }

        var match = CompilerDiagnostic().Match(line);
        if (!match.Success)
        {
            return;
        }

        Span<byte> hash = stackalloc byte[32];
        SHA256.HashData(Encoding.UTF8.GetBytes(line), hash);
        var key = MemoryMarshal.Read<DiagnosticKey>(hash);
        if (seen.Contains(key))
        {
            return;
        }

        if (seen.Count >= MaxDistinctDiagnostics)
        {
            SetLimit("diagnostic_limit");
            return;
        }
        seen.Add(key);
        bool error = match.Groups["level"].Value.Equals("error", StringComparison.OrdinalIgnoreCase);
        if (error)
        {
            ErrorCount++;
        }
        else
        {
            WarningCount++;
        }

        var rows = error ? Errors : Warnings;
        if (rows.Count < top)
        {
            rows.Add(new()
            {
                ["level"] = error ? "error" : "warning",
                ["code"] = Output.Safe(match.Groups["code"].Value, maxChars),
                ["location"] = Output.Safe(match.Groups["where"].Value, maxChars),
                ["message"] = Output.Safe(match.Groups["message"].Value, maxChars)
            });
        }
    }

    [GeneratedRegex(@"^\s*(?:(?<where>.*?)\s*:\s*)?(?<level>error|warning)\s+(?<code>[A-Za-z]+\d+)\s*:\s*(?<message>.*)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 250)]
    private static partial Regex CompilerDiagnostic();
}
