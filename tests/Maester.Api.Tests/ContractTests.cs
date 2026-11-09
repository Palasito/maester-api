using Maester.Api.Contracts;
using Xunit;

namespace Maester.Api.Tests;

public sealed class ContractTests
{
    [Fact]
    public void DefaultsMatchLegacyBackend()
    {
        var config = new CreateMaesterRunRequest().Normalize();
        Assert.Equal(["maester", "cisa", "eidsca", "orca", "cis"], config.Suites);
        Assert.Equal(5, config.Severity.Length);
        Assert.True(config.IncludeLongRunning);
        Assert.True(config.IncludePreview);
        Assert.Equal("", config.TenantId);
    }

    [Fact]
    public void FiltersAreCaseInsensitiveAndTagsAreSanitized()
    {
        var config = new CreateMaesterRunRequest { Suites = ["CIS", "unknown"], Severity = ["high"], Tags = ["MT.1001!", "??"], IncludePreview = false }.Normalize();
        Assert.Equal(["cis"], config.Suites);
        Assert.Equal(["High"], config.Severity);
        Assert.Equal(["MT.1001"], config.Tags);
        Assert.False(config.IncludePreview);
    }

    [Fact]
    public void UnknownSelectionsFallBackToDefaults()
    {
        var config = new CreateMaesterRunRequest { Suites = ["unknown"], Severity = [] }.Normalize();
        Assert.Equal(5, config.Suites.Length);
        Assert.Equal(5, config.Severity.Length);
    }

    [Fact]
    public void RejectsInvalidTenant()
    {
        Assert.Throws<ArgumentException>(() => new CreateMaesterRunRequest { TenantId = "not-a-tenant" }.Normalize());
    }
}