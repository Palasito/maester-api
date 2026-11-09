using Maester.Api.Contracts;
using Maester.Api.Endpoints;
using Maester.Api.Middleware;
using Maester.Api.Services;
using Microsoft.AspNetCore.RateLimiting;
using System.Threading.RateLimiting;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(options => options.Limits.MaxRequestBodySize = 65536);
builder.Services.Configure<RouteHandlerOptions>(options => options.ThrowOnBadRequest = true);
builder.Services.AddOptions<MaesterOptions>().BindConfiguration("Maester")
    .PostConfigure(options => options.DatabasePath = builder.Configuration["MAESTER_DB_PATH"] ?? options.DatabasePath)
    .Validate(options => options.MaxConcurrentJobs is >= 1 and <= 16 && options.TimeoutSeconds > 0 && options.RetentionSeconds > 0 &&
        options.MaxResultBytes > 0 && options.MaxRetainedJobs > 0 && options.SampleSeconds >= 1, "Invalid Maester limits.").ValidateOnStart();
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<IJobStore, JobStore>();
builder.Services.AddSingleton<RunCoordinator>();
builder.Services.AddSingleton<IRunCoordinator>(services => services.GetRequiredService<RunCoordinator>());
builder.Services.AddSingleton<IServiceTokenProvider, ServiceTokenProvider>();
builder.Services.AddSingleton<IScanRunner, PowerShellRunner>();
builder.Services.AddSingleton<IWorkerRegistry, WorkerRegistry>();
builder.Services.AddSingleton<IInventoryService, InventoryService>();
builder.Services.AddSingleton<HealthService>();
builder.Services.AddSingleton<IHealthService>(services => services.GetRequiredService<HealthService>());
builder.Services.AddHostedService(services => services.GetRequiredService<HealthService>());
builder.Services.AddHostedService<ScanWorker>();
builder.Services.AddRazorPages();
builder.Services.AddRateLimiter(options =>
{
    options.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(context =>
        context.Request.Path.StartsWithSegments("/api")
            ? RateLimitPartition.GetFixedWindowLimiter("api", _ => new FixedWindowRateLimiterOptions { PermitLimit = 120, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 })
            : RateLimitPartition.GetNoLimiter("public"));
    options.OnRejected = async (context, cancellationToken) =>
    {
        context.HttpContext.Response.StatusCode = 429;
        context.HttpContext.Response.Headers.RetryAfter = "60";
        await context.HttpContext.Response.WriteAsJsonAsync(new ApiErrorResponse("Too many requests. Please retry later."), cancellationToken);
    };
});
builder.Services.AddOpenApi();
var app = builder.Build();
app.UseMiddleware<ApiBoundary>();
app.UseRateLimiter();
app.UseStaticFiles();
app.MapRazorPages();
if (app.Environment.IsDevelopment())
    app.MapOpenApi();
app.MapMaester();
app.MapHealth();
app.Run();

public partial class Program;