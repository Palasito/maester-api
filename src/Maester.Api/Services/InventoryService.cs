using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Options;

namespace Maester.Api.Services;

/// <summary>A test definition from the baked Maester inventory.</summary>
public sealed record InventoryTestResponse(string Id, string? Title, string? Severity, string? Subcategory);
/// <summary>A Maester subcategory and its available tests.</summary>
public sealed record InventorySubcategoryResponse(string Id, string Name, int TestCount);
/// <summary>A suite of available security checks.</summary>
public sealed record InventorySuiteResponse(string Id, string Name, string Description, InventorySubcategoryResponse[] Subcategories, int TestCount, InventoryTestResponse[] Tests);
/// <summary>The versioned, build-time test inventory used by the scan worker.</summary>
public sealed record InventoryResponse(DateTimeOffset GeneratedAt, string Version, InventorySuiteResponse[] Suites, Dictionary<string, int> SeveritySummary, int TotalTestCount);

public interface IInventoryService
{
    InventoryResponse? Get();
}

public sealed class InventoryService(IOptions<MaesterOptions> settings, TimeProvider clock) : IInventoryService
{
    private readonly Lazy<InventoryResponse?> inventory = new(() => Load(settings.Value.TestsPath, clock));
    public InventoryResponse? Get() => inventory.Value;

    private static InventoryResponse? Load(string path, TimeProvider clock)
    {
        var configPath = Path.Combine(path, "maester-config.json");
        if (!File.Exists(configPath)) return null;
        using var document = JsonDocument.Parse(File.ReadAllText(configPath));
        var tests = document.RootElement.GetProperty("TestSettings").EnumerateArray().ToArray();
        var categories = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var directory in new[] { "Maester", "XSPM" })
        {
            var root = Path.Combine(path, directory);
            if (!Directory.Exists(root)) continue;
            foreach (var file in Directory.EnumerateFiles(root, "*.Tests.ps1", SearchOption.AllDirectories))
            {
                var relative = Path.GetRelativePath(root, file).Split(Path.DirectorySeparatorChar);
                var category = relative.Length < 2 || directory == "XSPM" || relative[0] == "Drift" ? "General" : relative[0];
                foreach (Match match in Regex.Matches(File.ReadAllText(file), @"MT\.\d+")) categories.TryAdd(match.Value, category);
            }
        }
        (string Id, string Name, string Prefix, string Description)[] definitions = [
            ("maester", "Maester Tests", "MT.", "Community security tests for Microsoft 365 and Azure"),
            ("eidsca", "EIDSCA Tests", "EIDSCA.", "Entra ID Security Config Analyzer"),
            ("cis", "CIS Benchmark Tests", "CIS.", "Microsoft 365 benchmark compliance checks"),
            ("cisa", "CISA SCuBA Tests", "CISA.", "Secure Cloud Business Applications baseline"),
            ("orca", "ORCA Tests", "ORCA.", "Exchange Online Protection configuration checks")];
        var suites = definitions.Select(definition =>
        {
            var selected = tests.Where(test => Text(test, "Id")?.StartsWith(definition.Prefix, StringComparison.OrdinalIgnoreCase) == true)
                .Select(test => new InventoryTestResponse(Text(test, "Id") ?? "", Text(test, "Title"), Text(test, "Severity"),
                    definition.Id == "maester" ? categories.GetValueOrDefault(Text(test, "Id") ?? "", "General") : null)).ToArray();
            var subcategories = definition.Id == "maester" ? selected.GroupBy(test => test.Subcategory ?? "General").OrderBy(group => group.Key)
                .Select(group => new InventorySubcategoryResponse("maester-" + group.Key.ToLowerInvariant(), group.Key, group.Count())).ToArray() : [];
            return new InventorySuiteResponse(definition.Id, definition.Name, definition.Description, subcategories, selected.Length, selected);
        }).ToArray();
        var severity = new[] { "Critical", "High", "Medium", "Low", "Info" }.ToDictionary(level => level,
            level => tests.Count(test => string.Equals(Text(test, "Severity"), level, StringComparison.OrdinalIgnoreCase)));
        var versionPath = Path.Combine(path, "runtime-info.json");
        var version = File.Exists(versionPath) ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(versionPath))?.GetValueOrDefault("Maester", "unknown") : "unknown";
        return new(clock.GetUtcNow(), version ?? "unknown", suites, severity, suites.Sum(suite => suite.TestCount));
    }

    private static string? Text(JsonElement element, string property) => element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}