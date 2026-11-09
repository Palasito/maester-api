using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Maester.Api.Services;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace Maester.Api.Tests;

public sealed class ApiTests
{
    [Fact]
    public async Task StartAndPollPreserveConsumerContract()
    {
        using var factory = new ApiFactory();
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Add("X-Functions-Key", "test-api-key");
        client.DefaultRequestHeaders.Add("Authorization", "Bearer downstream-token-for-tests");
        var response = await client.PostAsJsonAsync("/api/maester", new { suites = new[] { "maester" } });
        Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
        var accepted = await response.Content.ReadFromJsonAsync<JsonElement>();
        var jobId = accepted.GetProperty("jobId").GetString();
        Assert.Equal(32, jobId?.Length);
        var poll = await client.GetFromJsonAsync<JsonElement>($"/api/maester?jobId={jobId}");
        Assert.Equal("running", poll.GetProperty("status").GetString());
        Assert.Equal(JsonValueKind.Null, poll.GetProperty("result").ValueKind);
        Assert.Equal(JsonValueKind.Null, poll.GetProperty("error").ValueKind);
        Assert.Equal(HttpStatusCode.Conflict, (await client.PostAsJsonAsync("/api/maester", new { })).StatusCode);
    }

    [Theory]
    [InlineData("/api/maester?jobId=invalid", 400)]
    [InlineData("/api/maester?jobId=00000000000000000000000000000000", 404)]
    public async Task ErrorsHaveLegacyEnvelope(string path, int status)
    {
        using var factory = new ApiFactory();
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Add("X-Api-Key", "test-api-key");
        var response = await client.GetAsync(path);
        Assert.Equal(status, (int)response.StatusCode);
        Assert.True((await response.Content.ReadFromJsonAsync<JsonElement>()).TryGetProperty("error", out _));
    }

    [Fact]
    public async Task MissingKeyIsDeniedAndProbeIsPublic()
    {
        using var factory = new ApiFactory();
        using var client = factory.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/api/maester")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/health/live")).StatusCode);
    }

    [Fact]
    public async Task DashboardAndAssetsAreServedWithoutAuthentication()
    {
        using var factory = new ApiFactory();
        using var client = factory.CreateClient();
        var page = await client.GetStringAsync("/");
        Assert.Contains("Container health", page);
        foreach (var path in new[] { "/dashboard.css", "/dashboard.js", "/vendor/chart.umd.js", "/vendor/lucide.js", "/vendor/ibm-plex-sans-latin-400-normal.woff2" })
            Assert.Equal(HttpStatusCode.OK, (await client.GetAsync(path)).StatusCode);
    }

    [Fact]
    public async Task PublicTelemetryDoesNotExposePrivateScanData()
    {
        using var factory = new ApiFactory();
        using var client = factory.CreateClient();
        var store = factory.Services.GetRequiredService<IJobStore>();
        var job = store.TryCreate(new Contracts.CreateMaesterRunRequest { TenantId = "e1197991-dddd-4444-aaaa-123456789012" }.Normalize(), default)!;
        store.Finish(job.JobId, "{\"sensitiveEvidence\":\"private-data\"}", null);
        var health = await client.GetStringAsync("/health");
        Assert.DoesNotContain("private-data", health);
        Assert.DoesNotContain(job.JobId, health);
        Assert.DoesNotContain("e1197991", health);
        Assert.DoesNotContain("test-api-key", health);
        Assert.DoesNotContain("configuration", health);
        Assert.Contains("completed", health);
    }

    [Fact]
    public async Task BindingAndUnsupportedMethodErrorsRemainJson()
    {
        using var factory = new ApiFactory();
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Add("X-Api-Key", "test-api-key");
        var response = await client.PostAsync("/api/maester", new StringContent("{broken", System.Text.Encoding.UTF8, "application/json"));
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.True((await response.Content.ReadFromJsonAsync<JsonElement>()).TryGetProperty("error", out _));
        var unsupported = await client.DeleteAsync("/api/maester");
        Assert.Equal(HttpStatusCode.MethodNotAllowed, unsupported.StatusCode);
        Assert.True((await unsupported.Content.ReadFromJsonAsync<JsonElement>()).TryGetProperty("error", out _));
    }

    [Fact]
    public async Task OpenApiDocumentsAsyncScanStatus()
    {
        using var factory = new ApiFactory();
        using var client = factory.CreateClient();
        var document = await client.GetFromJsonAsync<JsonElement>("/openapi/v1.json");
        Assert.True(document.GetProperty("paths").GetProperty("/api/maester").GetProperty("post").GetProperty("responses").TryGetProperty("202", out _));
    }

    [Fact]
    public async Task AcceptedScanCompletesInIndependentWorkerAndCanBeReadTwice()
    {
        using var factory = new ApiFactory(enableWorkers: true);
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Add("X-Api-Key", "test-api-key");
        client.DefaultRequestHeaders.Add("Authorization", "Bearer private-test-token");
        var started = await client.PostAsJsonAsync("/api/maester", new { suites = new[] { "maester" } });
        Assert.Equal(HttpStatusCode.Accepted, started.StatusCode);
        var accepted = await started.Content.ReadFromJsonAsync<JsonElement>();
        var url = $"/api/maester?jobId={accepted.GetProperty("jobId").GetString()}";
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        JsonElement state;
        do
        {
            state = await client.GetFromJsonAsync<JsonElement>(url, deadline.Token);
            if (state.GetProperty("status").GetString() == "running") await Task.Delay(25, deadline.Token);
        } while (state.GetProperty("status").GetString() == "running");
        Assert.Equal("completed", state.GetProperty("status").GetString());
        Assert.Equal("[redacted]", state.GetProperty("result").GetProperty("detail").GetString());
        Assert.Equal("completed", (await client.GetFromJsonAsync<JsonElement>(url)).GetProperty("status").GetString());
    }

    [Fact]
    public async Task ProductionDoesNotExposeOpenApi()
    {
        using var factory = new ApiFactory(environment: "Production");
        using var client = factory.CreateClient();
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync("/openapi/v1.json")).StatusCode);
    }

    private sealed class ApiFactory(bool enableWorkers = false, string environment = "Development") : WebApplicationFactory<Program>
    {
        private readonly string directory = Path.Combine(Path.GetTempPath(), "maester-api-tests-" + Guid.NewGuid().ToString("N"));
        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            builder.UseContentRoot(Path.GetFullPath("../../../../../src/Maester.Api", AppContext.BaseDirectory));
            builder.UseEnvironment(environment);
            if (!enableWorkers)
                builder.ConfigureServices(services => services.RemoveAll<Microsoft.Extensions.Hosting.IHostedService>());
            builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["MAESTER_API_KEY"] = "test-api-key",
                ["Maester:DatabasePath"] = Path.Combine(directory, "jobs.db"),
                ["Maester:WorkerScript"] = Path.Combine(AppContext.BaseDirectory, "Fixtures", "success.ps1"),
                ["Logging:LogLevel:Default"] = "Warning"
            }));
        }
        protected override void Dispose(bool disposing)
        {
            base.Dispose(disposing);
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
    }
}