using System.Text.Json;
using Maester.Api.Contracts;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Options;

namespace Maester.Api.Services;

public interface IJobStore
{
    MaesterRunAcceptedResponse? TryCreate(RunConfiguration configuration, CancellationToken cancellationToken);
    MaesterJobResponse? Get(string jobId, CancellationToken cancellationToken);
    bool Finish(string jobId, string? result, string? error);
    void Cleanup();
    JobStatistics GetStatistics();
}

public sealed record JobStatistics(int Active, int Completed, int Failed, double AverageDurationMs);

public sealed class JobStore : IJobStore
{
    private readonly string connectionString;
    private readonly MaesterOptions options;
    private readonly TimeProvider clock;

    public JobStore(IOptions<MaesterOptions> settings, TimeProvider clock)
    {
        options = settings.Value;
        this.clock = clock;
        var path = Path.GetFullPath(options.DatabasePath);
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
        connectionString = new SqliteConnectionStringBuilder { DataSource = path, Pooling = false, DefaultTimeout = 5 }.ToString();
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS api_runs (
                job_id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, status TEXT NOT NULL,
                created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
                configuration TEXT NOT NULL, result TEXT, error TEXT
            );
            CREATE INDEX IF NOT EXISTS ix_api_runs_status ON api_runs(status, tenant_id);
            UPDATE api_runs SET status = 'failed', error = 'Scan interrupted by backend restart.', updated_at = $now
                WHERE status = 'running';
            """;
        command.Parameters.AddWithValue("$now", clock.GetUtcNow().ToUnixTimeMilliseconds());
        command.ExecuteNonQuery();
    }

    public MaesterRunAcceptedResponse? TryCreate(RunConfiguration configuration, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var connection = Open();
        using var transaction = connection.BeginTransaction(deferred: false);
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT COUNT(*), COALESCE(SUM(tenant_id = $tenant), 0) FROM api_runs WHERE status = 'running'";
        command.Parameters.AddWithValue("$tenant", configuration.TenantId);
        using (var reader = command.ExecuteReader())
        {
            reader.Read();
            if (reader.GetInt32(0) >= options.MaxConcurrentJobs || reader.GetInt32(1) > 0)
                return null;
        }
        var now = clock.GetUtcNow();
        var jobId = Guid.NewGuid().ToString("N");
        command.CommandText = "INSERT INTO api_runs VALUES ($id, $tenant, 'running', $now, $now, $configuration, NULL, NULL)";
        command.Parameters.AddWithValue("$id", jobId);
        command.Parameters.AddWithValue("$now", now.ToUnixTimeMilliseconds());
        command.Parameters.AddWithValue("$configuration", JsonSerializer.Serialize(configuration));
        command.ExecuteNonQuery();
        cancellationToken.ThrowIfCancellationRequested();
        transaction.Commit();
        return new(jobId, "running", now);
    }

    public MaesterJobResponse? Get(string jobId, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT * FROM api_runs WHERE job_id = $id AND (status = 'running' OR updated_at > $cutoff)";
        command.Parameters.AddWithValue("$id", jobId);
        command.Parameters.AddWithValue("$cutoff", clock.GetUtcNow().AddSeconds(-options.RetentionSeconds).ToUnixTimeMilliseconds());
        using var reader = command.ExecuteReader();
        if (!reader.Read()) return null;
        return new(reader.GetString(0), reader.GetString(2),
            DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64(3)), DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64(4)),
            reader.IsDBNull(6) ? null : JsonSerializer.Deserialize<JsonElement>(reader.GetString(6)),
            reader.IsDBNull(7) ? null : reader.GetString(7));
    }

    public bool Finish(string jobId, string? result, string? error)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = "UPDATE api_runs SET status = $status, result = $result, error = $error, updated_at = $now WHERE job_id = $id AND status = 'running'";
        command.Parameters.AddWithValue("$status", error is null ? "completed" : "failed");
        command.Parameters.AddWithValue("$result", (object?)result ?? DBNull.Value);
        command.Parameters.AddWithValue("$error", (object?)error ?? DBNull.Value);
        command.Parameters.AddWithValue("$now", clock.GetUtcNow().ToUnixTimeMilliseconds());
        command.Parameters.AddWithValue("$id", jobId);
        return command.ExecuteNonQuery() == 1;
    }

    public void Cleanup()
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = """
            DELETE FROM api_runs WHERE status != 'running' AND updated_at <= $cutoff;
            DELETE FROM api_runs WHERE job_id IN (
                SELECT job_id FROM api_runs WHERE status != 'running' ORDER BY updated_at DESC LIMIT -1 OFFSET $max
            );
            PRAGMA incremental_vacuum;
            """;
        command.Parameters.AddWithValue("$cutoff", clock.GetUtcNow().AddSeconds(-options.RetentionSeconds).ToUnixTimeMilliseconds());
        command.Parameters.AddWithValue("$max", options.MaxRetainedJobs);
        command.ExecuteNonQuery();
    }

    public JobStatistics GetStatistics()
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT COALESCE(SUM(status = 'running'), 0), COALESCE(SUM(status = 'completed'), 0),
                COALESCE(SUM(status = 'failed'), 0), COALESCE(AVG(CASE WHEN status != 'running' THEN updated_at - created_at END), 0)
            FROM api_runs
            """;
        using var reader = command.ExecuteReader();
        reader.Read();
        return new(reader.GetInt32(0), reader.GetInt32(1), reader.GetInt32(2), reader.GetDouble(3));
    }

    private SqliteConnection Open()
    {
        var connection = new SqliteConnection(connectionString);
        try { connection.Open(); return connection; }
        catch { connection.Dispose(); throw; }
    }
}