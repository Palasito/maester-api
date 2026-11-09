using System.Text;
using Maester.Api.Contracts;
using Maester.Api.Services;
using Microsoft.AspNetCore.Http.HttpResults;

namespace Maester.Api.Endpoints;

public static class HealthEndpoints
{
    public static void MapHealth(this WebApplication app)
    {
        app.MapGet("/health", (IHealthService health) => TypedResults.Ok(health.Get())).WithName("GetHealth").WithSummary("Read sanitized container health.");
        app.MapGet("/diag", (IHealthService health) => TypedResults.Ok(health.Get())).WithName("GetDiagnostics");
        app.MapGet("/diag/log", (IHealthService health) => TypedResults.File(Encoding.UTF8.GetBytes(health.ExportCsv()), "text/csv", "maester-health.csv"));
        app.MapGet("/health/live", () => TypedResults.Ok(new { status = "healthy" }));
        app.MapGet("/health/ready", Results<Ok<ReadinessResponse>, JsonHttpResult<ApiErrorResponse>> (IHealthService health) => health.Get().ScanReady
            ? TypedResults.Ok(new ReadinessResponse("ready"))
            : TypedResults.Json(new ApiErrorResponse("Worker test definitions are not available."), statusCode: 503));
        app.MapGet("/api/inventory", Results<Ok<InventoryResponse>, JsonHttpResult<ApiErrorResponse>> (IInventoryService inventory) => inventory.Get() is { } result
            ? TypedResults.Ok(result) : TypedResults.Json(new ApiErrorResponse("Test inventory is not available."), statusCode: 503)).WithName("GetInventory");
    }
}

/// <summary>Minimal startup readiness state.</summary>
public sealed record ReadinessResponse(string Status);