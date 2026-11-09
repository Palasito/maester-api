using System.Threading.Channels;
using Maester.Api.Contracts;
using Microsoft.Extensions.Options;

namespace Maester.Api.Services;

public sealed class RunCredentials(string graphToken, string? clientId, string? clientSecret)
{
    public string GraphToken { get; } = graphToken;
    public string? ClientId { get; } = clientId;
    public string? ClientSecret { get; } = clientSecret;
}

public sealed class RunWorkItem(string jobId, RunConfiguration configuration, RunCredentials credentials)
{
    public string JobId { get; } = jobId;
    public RunConfiguration Configuration { get; } = configuration;
    public RunCredentials Credentials { get; } = credentials;
}

public interface IRunCoordinator
{
    MaesterRunAcceptedResponse? Start(RunConfiguration configuration, RunCredentials credentials, CancellationToken cancellationToken);
}

public sealed class RunCoordinator(IJobStore store, IOptions<MaesterOptions> options) : IRunCoordinator
{
    private readonly object gate = new();
    private bool accepting = true;
    private readonly Channel<RunWorkItem> channel = Channel.CreateBounded<RunWorkItem>(options.Value.MaxConcurrentJobs);
    public ChannelReader<RunWorkItem> Reader => channel.Reader;

    public MaesterRunAcceptedResponse? Start(RunConfiguration configuration, RunCredentials credentials, CancellationToken cancellationToken)
    {
        lock (gate)
        {
            if (!accepting) return null;
            var accepted = store.TryCreate(configuration, cancellationToken);
            if (accepted is null) return null;
            if (channel.Writer.TryWrite(new(accepted.JobId, configuration, credentials))) return accepted;
            store.Finish(accepted.JobId, null, "Backend is shutting down. Please retry the scan.");
            return null;
        }
    }

    public void StopAccepting()
    {
        lock (gate)
        {
            accepting = false;
            channel.Writer.TryComplete();
        }
    }
}