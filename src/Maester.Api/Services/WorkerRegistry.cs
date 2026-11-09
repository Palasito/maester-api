using System.Collections.Concurrent;
using System.Diagnostics;

namespace Maester.Api.Services;

public interface IWorkerRegistry
{
    void Add(Process process);
    void Remove(Process process);
    (int Count, long MemoryBytes) Read();
}

public sealed class WorkerRegistry : IWorkerRegistry
{
    private readonly ConcurrentDictionary<int, Process> processes = new();
    public void Add(Process process) => processes.TryAdd(process.Id, process);
    public void Remove(Process process) => processes.TryRemove(process.Id, out _);
    public (int Count, long MemoryBytes) Read()
    {
        var count = 0;
        var memory = 0L;
        foreach (var process in processes.Values)
        {
            try
            {
                process.Refresh();
                if (process.HasExited) continue;
                memory += process.WorkingSet64;
                count++;
            }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        }
        return (count, memory);
    }
}