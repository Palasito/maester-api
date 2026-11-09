using System.Security.Cryptography;
using System.Text;
using Maester.Api.Contracts;

namespace Maester.Api.Middleware;

public sealed class ApiBoundary(RequestDelegate next, IConfiguration configuration, ILogger<ApiBoundary> logger)
{
    public async Task InvokeAsync(HttpContext context)
    {
        context.Response.Headers.CacheControl = "no-store";
        context.Response.Headers.XContentTypeOptions = "nosniff";
        try
        {
            if (context.Request.Path.StartsWithSegments("/api"))
            {
                var expected = configuration["MAESTER_API_KEY"];
                var supplied = context.Request.Headers["X-Functions-Key"].FirstOrDefault() ?? context.Request.Headers["X-Api-Key"].FirstOrDefault();
                if (string.IsNullOrEmpty(expected) || string.IsNullOrEmpty(supplied) ||
                    !CryptographicOperations.FixedTimeEquals(SHA256.HashData(Encoding.UTF8.GetBytes(expected)), SHA256.HashData(Encoding.UTF8.GetBytes(supplied))))
                {
                    await Error(context, 401, "Invalid or missing API key.");
                    return;
                }
            }
            await next(context);
            if (!context.Response.HasStarted && context.Response.StatusCode >= 400 && context.Response.ContentType is null)
                await Error(context, context.Response.StatusCode, "Request could not be processed.");
        }
        catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested) { }
        catch (BadHttpRequestException exception)
        {
            await Error(context, exception.StatusCode, exception.StatusCode == 413 ? "Request body too large." : "Invalid request body.");
        }
        catch (ArgumentException)
        {
            await Error(context, 400, "Invalid request parameters.");
        }
        catch (Exception exception)
        {
            logger.LogError("Request failed ({ExceptionType}).", exception.GetType().Name);
            if (!context.Response.HasStarted) await Error(context, 500, "An internal error occurred.");
            else context.Abort();
        }
    }

    private static Task Error(HttpContext context, int status, string message)
    {
        context.Response.StatusCode = status;
        return context.Response.WriteAsJsonAsync(new ApiErrorResponse(message), context.RequestAborted);
    }
}