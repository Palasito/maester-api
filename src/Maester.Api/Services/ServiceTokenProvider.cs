using Microsoft.Identity.Client;

namespace Maester.Api.Services;

public interface IServiceTokenProvider
{
    Task<IReadOnlyDictionary<string, string?>?> AcquireAsync(RunWorkItem work, CancellationToken cancellationToken);
}

public sealed class ServiceTokenProvider : IServiceTokenProvider
{
    public async Task<IReadOnlyDictionary<string, string?>?> AcquireAsync(RunWorkItem work, CancellationToken cancellationToken)
    {
        if (string.IsNullOrEmpty(work.Credentials.ClientId) || string.IsNullOrEmpty(work.Credentials.ClientSecret) || string.IsNullOrEmpty(work.Configuration.TenantId))
            return null;
        var client = ConfidentialClientApplicationBuilder.Create(work.Credentials.ClientId)
            .WithClientSecret(work.Credentials.ClientSecret)
            .WithAuthority($"https://login.microsoftonline.com/{work.Configuration.TenantId}").Build();
        string[] scopes = ["https://graph.microsoft.com/.default", "https://outlook.office365.com/.default",
            "https://ps.compliance.protection.outlook.com/.default", "48ac35b8-9aa8-4d74-927d-1f4a14a0b239/.default", "https://management.azure.com/.default"];
        var tokens = new Dictionary<string, string?>();
        foreach (var scope in scopes)
        {
            try { tokens[scope] = (await client.AcquireTokenForClient([scope]).ExecuteAsync(cancellationToken)).AccessToken; }
            catch (MsalException) when (scope != scopes[0]) { tokens[scope] = null; }
        }
        return tokens;
    }
}