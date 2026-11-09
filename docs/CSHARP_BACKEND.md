# C# Backend

The C# service is an opt-in replacement for the Pode host. Nexus, PipePal,
ADAM and GOV are unchanged. The existing Dockerfile and deployment pipeline
still build/deploy the legacy host until a separately reviewed cutover.

## Run Locally

From the maester-api repository, with .NET SDK 10.0.401 and PowerShell 7:

```powershell
dotnet test tests/Maester.Api.Tests/Maester.Api.Tests.csproj -c Release
dotnet run --project src/Maester.Api
```

The dashboard is at http://localhost:7072. The public dashboard has no scan
controls and exposes no tenant names, identifiers, results, credentials or
raw worker logs. A local host without Maester modules/test definitions can
display health but cannot execute scans; readiness returns 503.

Set MAESTER_API_KEY privately in the process environment before using /api/*.
Do not put real keys or tokens in the checked-in request harness. The
forwarded Graph token is a downstream credential, not an access token issued
for this backend. The shared API key authorizes the trusted proxy.

## Linux Container

```powershell
docker build -f Dockerfile.csharp -t maester-api-csharp:local .
docker run --rm --init -p 7072:8080 --memory=2g --cpus=1 --env MAESTER_API_KEY maester-api-csharp:local
```

The runtime is non-root ASP.NET Core plus a separate PowerShell executable.
Modules are pinned in build/modules.json. Tests are pinned to the Maester
2.3.0 release commit. Imports are verified at build time; nothing is fetched
at startup. Pode and its patches are not part of this image. Dashboard
assets are vendored, including their licenses: Chart.js 4.5.1, Lucide 0.468.0,
and IBM Plex Sans (@fontsource 5.2.6).

## Configuration

| Setting | Default | Meaning |
| --- | --- | --- |
| MAESTER_API_KEY | none | Required shared key; missing means deny API requests |
| MAESTER_DB_PATH | data/maester-csharp.db | Private transient SQLite database |
| Maester__MaxConcurrentJobs | 1 | Global capacity; each tenant also limited to one scan |
| Maester__TimeoutSeconds | 1800 | Deadline including OAuth and worker execution |
| Maester__RetentionSeconds | 7200 | Result retention after terminal transition |
| Maester__MaxRetainedJobs | 1000 | Maximum terminal rows retained |
| Maester__MaxResultBytes | 16777216 | Largest accepted worker result |
| Maester__SampleSeconds | 30 | Health sampling interval |
| Maester__TestsPath | /app/maester-tests | Immutable suite and inventory directory |
| Maester__PowerShellExecutable | pwsh | Worker executable, not caller-configurable |

POST /api/maester returns 202 and the existing jobId/status/createdAt fields.
GET /api/maester?jobId=... returns the existing result/error envelope. A GET
does not delete completed results. Client disconnects do not cancel admitted
scans. Timeout/shutdown kills the child process tree before capacity is
released. Credentials travel through stdin, not argv or SQLite. Raw process
output is drained and discarded; excessive output terminates the worker.
Authenticated results retain service diagnostics and test evidence, but known
request/service credentials are redacted before storage.

The health snapshot is replica-local and bounded to 2880 samples maximum.
Execution counts describe currently retained jobs, not permanent totals.
Container cgroup measurements that are unavailable are null, not host-wide
estimates or misleading zeroes. The web-process RSS, managed heap, child RSS
and total container memory are separate measurements.

## Azure Container Apps

Use a Linux app with target port 8080, minReplicas=maxReplicas=1, and one active
revision. Configure /health/live for liveness, /health/ready for readiness,
and generous startup probes for initial image pull/start. Do not configure
HTTP-based scale-to-zero while this process owns background scans.

Local SQLite is NOT durable across replica replacement. A process restart
with the same database marks interrupted scans failed; replica replacement
may lose all job/result rows. Drain scans and collect results before deploying
a new revision. Do not mount SQLite WAL on a network file share as a shortcut
to distributed job storage. Short retention does not guarantee delivery after
an infrastructure failure.

For cutover, update the existing PipePal MAESTER backend URL setting to the
staged ACA endpoint and keep the API key consistent. Verify both scan and
inventory proxies. No consumer source change is intended. Do not put blanket
Entra/Easy Auth in front of /api/*: it would reject existing proxy calls using
Graph-audience tokens. Protect static API-key settings with platform secrets
or Key Vault references; never expose them through the public dashboard.

Live tenant scans, Azure deployment, right-sizing and a 24-hour soak are
separate validation gates. No Azure resource or production setting is changed
by adding this implementation.