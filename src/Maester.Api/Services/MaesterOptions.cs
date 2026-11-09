namespace Maester.Api.Services;

public sealed class MaesterOptions
{
    public string DatabasePath { get; set; } = "data/maester-csharp.db";
    public string PowerShellExecutable { get; set; } = "pwsh";
    public string WorkerScript { get; set; } = Path.Combine(AppContext.BaseDirectory, "worker/run.ps1");
    public string TestsPath { get; set; } = "/app/maester-tests";
    public int MaxConcurrentJobs { get; set; } = 1;
    public int TimeoutSeconds { get; set; } = 1800;
    public int RetentionSeconds { get; set; } = 7200;
    public int MaxRetainedJobs { get; set; } = 1000;
    public int MaxResultBytes { get; set; } = 16 * 1024 * 1024;
    public int SampleSeconds { get; set; } = 30;
}