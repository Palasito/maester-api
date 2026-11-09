using System.Text.Json;
using System.Text.RegularExpressions;

namespace Maester.Api.Contracts;

/// <summary>Options for an asynchronous Maester scan.</summary>
public sealed record CreateMaesterRunRequest
{
    public string[]? Suites { get; init; }
    public string[]? Severity { get; init; }
    public string[]? Tags { get; init; }
    public bool? IncludeLongRunning { get; init; }
    public bool? IncludePreview { get; init; }
    public string? TenantId { get; init; }

    public RunConfiguration Normalize()
    {
        if (!string.IsNullOrEmpty(TenantId) && !Guid.TryParse(TenantId, out _))
            throw new ArgumentException("Invalid tenantId format. Must be a valid GUID.");
        return new(
            Select(Suites, ["maester", "cisa", "eidsca", "orca", "cis", "xspm"], ["maester", "cisa", "eidsca", "orca", "cis"]),
            Select(Severity, ["Critical", "High", "Medium", "Low", "Info"], ["Critical", "High", "Medium", "Low", "Info"]),
            (Tags ?? []).Where(tag => tag is not null).Select(tag => Regex.Replace(tag, "[^A-Za-z0-9.:_\\-]", "")).Where(tag => tag.Length > 0).ToArray(),
            IncludeLongRunning ?? true, IncludePreview ?? true,
            string.IsNullOrEmpty(TenantId) ? "" : Guid.Parse(TenantId).ToString("D"));
    }

    private static string[] Select(string[]? requested, string[] allowed, string[] defaults)
    {
        var selected = (requested ?? []).Select(value => allowed.FirstOrDefault(item => string.Equals(item, value, StringComparison.OrdinalIgnoreCase)))
            .OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        return selected.Length == 0 ? defaults : selected;
    }
}

public sealed record RunConfiguration(string[] Suites, string[] Severity, string[] Tags, bool IncludeLongRunning, bool IncludePreview, string TenantId);

/// <summary>An accepted scan and its polling identifier.</summary>
public sealed record MaesterRunAcceptedResponse(string JobId, string Status, DateTimeOffset CreatedAt);

/// <summary>Current scan state, with a retained result after completion.</summary>
public sealed record MaesterJobResponse(string JobId, string Status, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt, JsonElement? Result, string? Error);

/// <summary>A safe error message compatible with the existing consumer.</summary>
public sealed record ApiErrorResponse(string Error);