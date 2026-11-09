using Maester.Api.Contracts;
using Maester.Api.Services;
using Microsoft.AspNetCore.Http.HttpResults;

namespace Maester.Api.Endpoints;

public static class MaesterEndpoints
{
    public static void MapMaester(this WebApplication app)
    {
        app.MapPost("/api/maester", Start).WithName("StartMaesterRun").WithSummary("Start an isolated Maester scan.");
        app.MapGet("/api/maester", Get).WithName("GetMaesterRun").WithSummary("Poll scan state without consuming its retained result.");
    }

    private static Results<Accepted<MaesterRunAcceptedResponse>, UnauthorizedHttpResult, Conflict<ApiErrorResponse>, BadRequest<ApiErrorResponse>> Start(
        CreateMaesterRunRequest request, HttpContext context, IRunCoordinator coordinator, CancellationToken cancellationToken)
    {
        var authorization = context.Request.Headers.Authorization.ToString();
        if (!authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) || authorization[7..].Trim().Length < 10)
            return TypedResults.Unauthorized();
        RunConfiguration config;
        try { config = request.Normalize(); }
        catch (ArgumentException) { return TypedResults.BadRequest(new ApiErrorResponse("Invalid tenantId format. Must be a valid GUID.")); }
        var credentials = new RunCredentials(authorization[7..].Trim(), context.Request.Headers["X-Maester-Client-Id"].FirstOrDefault(), context.Request.Headers["X-Maester-Client-Secret"].FirstOrDefault());
        if ((!string.IsNullOrEmpty(credentials.ClientId) && !Guid.TryParse(credentials.ClientId, out _)) ||
            string.IsNullOrEmpty(credentials.ClientId) != string.IsNullOrEmpty(credentials.ClientSecret))
            return TypedResults.BadRequest(new ApiErrorResponse("Provide a valid client ID and client secret together."));
        var accepted = coordinator.Start(config, credentials, cancellationToken);
        return accepted is null
            ? TypedResults.Conflict(new ApiErrorResponse("Scan capacity is busy or a scan is already running for this tenant. Please retry later."))
            : TypedResults.Accepted($"/api/maester?jobId={accepted.JobId}", accepted);
    }

    private static Results<Ok<MaesterJobResponse>, BadRequest<ApiErrorResponse>, NotFound<ApiErrorResponse>> Get(
        string? jobId, IJobStore store, CancellationToken cancellationToken)
    {
        if (jobId?.Length != 32 || !Guid.TryParseExact(jobId, "N", out _))
            return TypedResults.BadRequest(new ApiErrorResponse("Missing or invalid jobId. Expected a 32-character hexadecimal identifier."));
        var job = store.Get(jobId.ToLowerInvariant(), cancellationToken);
        return job is null ? TypedResults.NotFound(new ApiErrorResponse("Job not found.")) : TypedResults.Ok(job);
    }
}