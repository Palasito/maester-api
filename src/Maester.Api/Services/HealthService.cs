using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Extensions.Options;

namespace Maester.Api.Services;

/// <summary>One allowlisted resource sample. Unavailable measurements remain null.</summary>
public sealed record ResourceSample(DateTimeOffset Timestamp, double? CpuPercent, long? ContainerMemoryBytes,
    long? ContainerMemoryLimitBytes, long? WorkingSetBytes, long ProcessMemoryBytes, long ManagedHeapBytes,
    long? CommittedHeapBytes, int Gen0Collections, int Gen1Collections, int Gen2Collections, int ThreadCount,
    int WorkerCount, long WorkerMemoryBytes, long DatabaseBytes, long? DiskFreeBytes);

/// <summary>Public aggregate health, without tenant, job, credential or result information.</summary>
public sealed record HealthResponse(string Status, DateTimeOffset StartedAt, double UptimeSeconds, int SampleSeconds,
    int Capacity, bool ScanReady, string Runtime, string Platform, string Version, IReadOnlyDictionary<string, string> Modules, JobStatistics Jobs, ResourceSample[] Samples);

public interface IHealthService
{
    HealthResponse Get();
    string ExportCsv();
}

public sealed class HealthService(IJobStore store, IWorkerRegistry workers, IOptions<MaesterOptions> settings,
    TimeProvider clock, ILogger<HealthService> logger) : BackgroundService, IHealthService
{
    private readonly object gate = new();
    private readonly Queue<ResourceSample> samples = new();
    private readonly DateTimeOffset started = clock.GetUtcNow();
    private long? lastCpuUsec;
    private DateTimeOffset? lastSample;
    private readonly Lazy<IReadOnlyDictionary<string, string>> modules = new(() =>
    {
        var path = Path.Combine(settings.Value.TestsPath, "runtime-info.json");
        if (!File.Exists(path)) return new Dictionary<string, string>();
        var loaded = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path)) ?? [];
        string[] allowed = ["Maester", "Pester", "Microsoft.Graph.Authentication", "ExchangeOnlineManagement", "MicrosoftTeams", "Az.Accounts", "PowerShell", "TestRevision"];
        return loaded.Where(item => allowed.Contains(item.Key)).ToDictionary();
    });

    public HealthResponse Get()
    {
        ResourceSample[] snapshot;
        lock (gate) snapshot = samples.ToArray();
        var options = settings.Value;
        var scanReady = File.Exists(options.WorkerScript) && File.Exists(Path.Combine(options.TestsPath, "maester-config.json"));
        return new(snapshot.Length == 0 ? "starting" : "healthy", started, (clock.GetUtcNow() - started).TotalSeconds,
            options.SampleSeconds, options.MaxConcurrentJobs, scanReady, RuntimeInformation.FrameworkDescription,
            RuntimeInformation.OSDescription, typeof(HealthService).Assembly.GetName().Version?.ToString() ?? "unknown", modules.Value, store.GetStatistics(), snapshot);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(settings.Value.SampleSeconds), clock);
        do
        {
            try { Sample(); store.Cleanup(); }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                logger.LogWarning("Health sampling failed ({ExceptionType}).", exception.GetType().Name);
            }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    private void Sample()
    {
        using var process = Process.GetCurrentProcess();
        var now = clock.GetUtcNow();
        var cpu = ReadStat("/sys/fs/cgroup/cpu.stat", "usage_usec");
        var quota = ReadCpuQuota();
        double? percent = cpu.HasValue && lastCpuUsec.HasValue && lastSample.HasValue && quota > 0
            ? Math.Max(0, (cpu.Value - lastCpuUsec.Value) / (now - lastSample.Value).TotalMicroseconds / quota.Value * 100) : null;
        lastCpuUsec = cpu;
        lastSample = now;
        var memory = ReadLong("/sys/fs/cgroup/memory.current") ?? ReadLong("/sys/fs/cgroup/memory/memory.usage_in_bytes");
        var memoryLimit = ReadLong("/sys/fs/cgroup/memory.max") ?? ReadLong("/sys/fs/cgroup/memory/memory.limit_in_bytes");
        if (memoryLimit > 1L << 60) memoryLimit = null;
        var inactive = ReadStat("/sys/fs/cgroup/memory.stat", "inactive_file");
        var gc = GC.GetGCMemoryInfo();
        var child = workers.Read();
        var db = settings.Value.DatabasePath;
        var databaseBytes = new[] { db, db + "-wal", db + "-shm" }.Where(File.Exists).Sum(path => new FileInfo(path).Length);
        long? diskFree = null;
        try { diskFree = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(db)) ?? "/").AvailableFreeSpace; }
        catch (IOException) { }
        var sample = new ResourceSample(now, percent, memory, memoryLimit, memory.HasValue && inactive.HasValue ? Math.Max(0, memory.Value - inactive.Value) : null,
            process.WorkingSet64, GC.GetTotalMemory(false), gc.Index == 0 ? null : gc.TotalCommittedBytes, GC.CollectionCount(0), GC.CollectionCount(1), GC.CollectionCount(2),
            process.Threads.Count, child.Count, child.MemoryBytes, databaseBytes, diskFree);
        lock (gate)
        {
            samples.Enqueue(sample);
            while (samples.Count > Math.Min(2880, Math.Max(1, 86400 / settings.Value.SampleSeconds))) samples.Dequeue();
        }
    }

    public string ExportCsv()
    {
        var lines = Get().Samples.Select(sample => string.Join(',', sample.Timestamp.ToString("O"),
            sample.CpuPercent?.ToString("F2", CultureInfo.InvariantCulture), sample.ContainerMemoryBytes, sample.ContainerMemoryLimitBytes,
            sample.ProcessMemoryBytes, sample.ManagedHeapBytes, sample.WorkerCount, sample.WorkerMemoryBytes, sample.DatabaseBytes));
        return "timestamp,cpuPercent,containerMemoryBytes,containerLimitBytes,processMemoryBytes,managedHeapBytes,workers,workerMemoryBytes,databaseBytes\n" + string.Join('\n', lines);
    }

    private static double? ReadCpuQuota()
    {
        var text = ReadText("/sys/fs/cgroup/cpu.max")?.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (text?.Length == 2 && double.TryParse(text[0], CultureInfo.InvariantCulture, out var quota) && double.TryParse(text[1], CultureInfo.InvariantCulture, out var period) && period > 0)
            return quota / period;
        var v1Quota = ReadLong("/sys/fs/cgroup/cpu/cpu.cfs_quota_us");
        var v1Period = ReadLong("/sys/fs/cgroup/cpu/cpu.cfs_period_us");
        return v1Quota > 0 && v1Period > 0 ? (double)v1Quota / v1Period : null;
    }

    private static long? ReadStat(string path, string name)
    {
        var entry = ReadText(path)?.Split('\n').Select(line => line.Split(' ', StringSplitOptions.RemoveEmptyEntries)).FirstOrDefault(parts => parts.Length == 2 && parts[0] == name);
        return entry is not null && long.TryParse(entry[1], CultureInfo.InvariantCulture, out var value) ? value : null;
    }

    private static long? ReadLong(string path) => long.TryParse(ReadText(path)?.Trim(), CultureInfo.InvariantCulture, out var value) ? value : null;
    private static string? ReadText(string path)
    {
        try { return File.Exists(path) ? File.ReadAllText(path) : null; }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }
}