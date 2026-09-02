# lib/db.ps1 — SQLite data access helpers for Maester job persistence
#
# All database operations go through this module. Uses raw ADO.NET
# (Microsoft.Data.Sqlite) with proper try/finally/Dispose for every
# Connection, Command, and DataReader — eliminates the disposal
# deficiency in PSSQLite that promoted objects to Gen2 and caused
# ~0.2 MB/hour of unnecessary memory retention.
#
# Microsoft.Data.Sqlite + SQLitePCLRaw replaces PSSQLite's
# System.Data.SQLite which required a Windows-only native interop DLL.
#
# ─── Usage ───────────────────────────────────────────────────────
# . /app/lib/db.ps1                         # dot-source in server.ps1
# Initialize-MaesterDb -DbPath $DB_PATH     # create table + WAL mode
# New-MaesterJob -DbPath $DB_PATH -JobId $id -Suites @('maester') -Severity @('High')
# ─────────────────────────────────────────────────────────────────

# ── Load Microsoft.Data.Sqlite + SQLitePCLRaw assemblies ─────────────────────
$_sqliteLibDir = '/app/sqlite-libs'

# Register assembly resolver so cross-references between packages are found.
[System.AppDomain]::CurrentDomain.add_AssemblyResolve({
    param($sender, $resolveArgs)
    $name = [System.Reflection.AssemblyName]::new($resolveArgs.Name).Name
    $path = [System.IO.Path]::Combine('/app/sqlite-libs', "$name.dll")
    if ([System.IO.File]::Exists($path)) {
        return [System.Reflection.Assembly]::LoadFrom($path)
    }
    return $null
})

# Load assemblies in dependency order.
@(
    'SQLitePCLRaw.core.dll'
    'SQLitePCLRaw.provider.e_sqlite3.dll'
    'SQLitePCLRaw.batteries_v2.dll'
    'Microsoft.Data.Sqlite.dll'
) | ForEach-Object {
    $p = [System.IO.Path]::Combine($_sqliteLibDir, $_)
    [System.Reflection.Assembly]::LoadFrom($p) | Out-Null
}

# Initialise native SQLite binding (must happen once before any connection).
[SQLitePCL.Batteries_V2]::Init()

# ── Internal: Execute a parameterised query with full Dispose ─────────────────
function Invoke-MaesterSql {
    <#
    .SYNOPSIS  Execute a SQL query against SQLite with proper ADO.NET disposal.
               Returns PSObjects for SELECT queries, nothing for DML.
    #>
    param(
        [Parameter(Mandatory)][string]$DbPath,
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Parameters
    )

    $connStr  = "Data Source=$DbPath"
    $conn     = $null
    $cmd      = $null
    $reader   = $null
    $isSelect = $Query.TrimStart().StartsWith('SELECT', [System.StringComparison]::OrdinalIgnoreCase) -or
                $Query.TrimStart().StartsWith('PRAGMA',  [System.StringComparison]::OrdinalIgnoreCase)
    try {
        $conn = [Microsoft.Data.Sqlite.SqliteConnection]::new($connStr)
        $conn.Open()

        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query

        if ($Parameters) {
            foreach ($kv in $Parameters.GetEnumerator()) {
                if ($null -ne $kv.Value) {
                    $val = $kv.Value
                    if ($val -is [datetime]) { $val = $val.ToString('yyyy-MM-dd HH:mm:ss') }
                    $null = $cmd.Parameters.AddWithValue("@$($kv.Key)", $val)
                } else {
                    $null = $cmd.Parameters.AddWithValue("@$($kv.Key)", [DBNull]::Value)
                }
            }
        }

        if ($isSelect) {
            $reader = $cmd.ExecuteReader()
            while ($reader.Read()) {
                $obj = [ordered]@{}
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $obj[$reader.GetName($i)] = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
                }
                [PSCustomObject]$obj
            }
        } else {
            $null = $cmd.ExecuteNonQuery()
        }
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($cmd)    { $cmd.Dispose() }
        if ($conn)   { $conn.Dispose() }
    }
}

# ── Initialise database & schema ──────────────────────────────────────────────

function Initialize-MaesterDb {
    <#
    .SYNOPSIS  Create the jobs table (idempotent) and enable WAL journal mode.
    #>
    param([Parameter(Mandatory)][string]$DbPath)

    Invoke-MaesterSql -DbPath $DbPath -Query @"
        CREATE TABLE IF NOT EXISTS jobs (
            job_id       TEXT    PRIMARY KEY,
            status       TEXT    NOT NULL DEFAULT 'running',
            created_at   TEXT    NOT NULL,
            updated_at   TEXT    NOT NULL,
            suites       TEXT,
            severity     TEXT,
            result       TEXT,
            error        TEXT,
            duration_ms  INTEGER,
            tenant_id    TEXT    NOT NULL DEFAULT ''
        );
"@

    # Migrate existing databases that pre-date the tenant_id column
    try {
        Invoke-MaesterSql -DbPath $DbPath -Query 'ALTER TABLE jobs ADD COLUMN tenant_id TEXT NOT NULL DEFAULT "";'
    } catch {
        # Column already exists — safe to ignore
    }

    # Persistent statistics table — survives job deletion
    Invoke-MaesterSql -DbPath $DbPath -Query @"
        CREATE TABLE IF NOT EXISTS job_stats (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            job_id        TEXT    NOT NULL,
            status        TEXT    NOT NULL,
            duration_ms   INTEGER NOT NULL DEFAULT 0,
            suites        TEXT,
            completed_at  TEXT    NOT NULL
        );
"@

    # WAL mode: concurrent readers + single writer, non-blocking reads
    Invoke-MaesterSql -DbPath $DbPath -Query 'PRAGMA journal_mode=WAL;'
    # Wait up to 5 s for a write lock instead of failing immediately
    Invoke-MaesterSql -DbPath $DbPath -Query 'PRAGMA busy_timeout=5000;'
}

# ── CRUD operations ───────────────────────────────────────────────────────────

function New-MaesterJob {
    <#
    .SYNOPSIS  Insert a new job row with status 'running'.
    #>
    param(
        [Parameter(Mandatory)][string]   $DbPath,
        [Parameter(Mandatory)][string]   $JobId,
        [Parameter(Mandatory)][string[]] $Suites,
        [string[]] $Severity
    )

    $now = [datetime]::UtcNow.ToString('o')
    Invoke-MaesterSql -DbPath $DbPath -Query @"
        INSERT INTO jobs (job_id, status, created_at, updated_at, suites, severity)
        VALUES (@jobId, 'running', @now, @now, @suites, @severity)
"@ -Parameters @{
        jobId    = $JobId
        now      = $now
        suites   = ($Suites   | ConvertTo-Json -Compress)
        severity = if ($Severity) { ($Severity | ConvertTo-Json -Compress) } else { '[]' }
    }
}

function Get-MaesterJob {
    <#
    .SYNOPSIS  Return a single job row or $null if not found.
    #>
    param(
        [Parameter(Mandatory)][string] $DbPath,
        [Parameter(Mandatory)][string] $JobId
    )

    Invoke-MaesterSql -DbPath $DbPath -Query @"
        SELECT * FROM jobs WHERE job_id = @jobId
"@ -Parameters @{ jobId = $JobId }
}

function Update-MaesterJob {
    <#
    .SYNOPSIS  Set a job's terminal state (completed / failed) with result data.
    #>
    param(
        [Parameter(Mandatory)][string] $DbPath,
        [Parameter(Mandatory)][string] $JobId,
        [Parameter(Mandatory)][string] $Status,
        [string] $Result,       # JSON string — PipePal-format result
        [string] $ErrorMsg,
        [int]    $DurationMs = 0
    )

    $now = [datetime]::UtcNow.ToString('o')
    Invoke-MaesterSql -DbPath $DbPath -Query @"
        UPDATE jobs
        SET    status      = @status,
               updated_at  = @now,
               result      = @result,
               error       = @errorMsg,
               duration_ms = @durationMs
        WHERE  job_id      = @jobId
"@ -Parameters @{
        jobId      = $JobId
        status     = $Status
        now        = $now
        result     = $Result
        errorMsg   = $ErrorMsg
        durationMs = $DurationMs
    }
}

function Remove-MaesterJob {
    <#
    .SYNOPSIS  Delete a single job by ID (used after returning terminal results).
    #>
    param(
        [Parameter(Mandatory)][string] $DbPath,
        [Parameter(Mandatory)][string] $JobId
    )

    Invoke-MaesterSql -DbPath $DbPath -Query @"
        DELETE FROM jobs WHERE job_id = @jobId
"@ -Parameters @{ jobId = $JobId }
}

# ── Cleanup helpers ───────────────────────────────────────────────────────────

function Remove-ExpiredJobs {
    <#
    .SYNOPSIS  Batch-delete old jobs.
        • Hard cutoff  — anything older than $MaxAgeHours (default 2h)
        • Soft cutoff  — completed/failed older than $CompletedTimeoutMinutes (default 10min)
    #>
    param(
        [Parameter(Mandatory)][string] $DbPath,
        [int] $MaxAgeHours             = 2,
        [int] $CompletedTimeoutMinutes = 10
    )

    $hardCutoff      = [datetime]::UtcNow.AddHours(  -$MaxAgeHours            ).ToString('o')
    $completedCutoff = [datetime]::UtcNow.AddMinutes( -$CompletedTimeoutMinutes).ToString('o')

    # Hard: remove everything past max age
    Invoke-MaesterSql -DbPath $DbPath -Query @"
        DELETE FROM jobs WHERE created_at < @cutoff
"@ -Parameters @{ cutoff = $hardCutoff }

    # Soft: remove terminal-state jobs past the completed timeout
    Invoke-MaesterSql -DbPath $DbPath -Query @"
        DELETE FROM jobs
        WHERE  status IN ('completed', 'failed')
          AND  updated_at < @cutoff
"@ -Parameters @{ cutoff = $completedCutoff }
}

function Get-RunningJobCount {
    <#
    .SYNOPSIS  Return the number of jobs currently in 'running' state.
    #>
    param([Parameter(Mandatory)][string] $DbPath)

    $row = Invoke-MaesterSql -DbPath $DbPath -Query @"
        SELECT COUNT(*) AS cnt FROM jobs WHERE status = 'running'
"@
    return [int]$row.cnt
}

function Set-StaleJobsTimedOut {
    <#
    .SYNOPSIS  Mark running jobs older than $StaleMinutes as 'failed' (timeout).
    #>
    param(
        [Parameter(Mandatory)][string] $DbPath,
        [int] $StaleMinutes = 30
    )

    $cutoff = [datetime]::UtcNow.AddMinutes(-$StaleMinutes).ToString('o')
    $now    = [datetime]::UtcNow.ToString('o')

    Invoke-MaesterSql -DbPath $DbPath -Query @"
        UPDATE jobs
        SET    status     = 'failed',
               error      = 'Job timed out (stale detection). Container may have restarted.',
               updated_at = @now
        WHERE  status = 'running'
          AND  created_at < @cutoff
"@ -Parameters @{ cutoff = $cutoff; now = $now }
}

# ── Stats / History ───────────────────────────────────────────────────────────

function Record-JobCompletion {
    <#
    .SYNOPSIS  Persist a snapshot into job_stats when a job reaches terminal state.
               Called before the job row is deleted, so historical stats survive cleanup.
    #>
    param(
        [Parameter(Mandatory)][string] $DbPath,
        [Parameter(Mandatory)][string] $JobId,
        [Parameter(Mandatory)][string] $Status,
        [int]    $DurationMs = 0,
        [string] $Suites     = ''
    )

    $now = [datetime]::UtcNow.ToString('o')
    Invoke-MaesterSql -DbPath $DbPath -Query @"
        INSERT INTO job_stats (job_id, status, duration_ms, suites, completed_at)
        VALUES (@jobId, @status, @durationMs, @suites, @now)
"@ -Parameters @{
        jobId      = $JobId
        status     = $Status
        durationMs = $DurationMs
        suites     = $Suites
        now        = $now
    }
}

function Get-JobStats {
    <#
    .SYNOPSIS  Aggregate statistics from the persistent job_stats table.
    .OUTPUTS   [PSCustomObject] with totalCompleted, totalFailed, avgDurationMs,
               minDurationMs, maxDurationMs, lastCompletedAt.
    #>
    param([Parameter(Mandatory)][string] $DbPath)

    $row = Invoke-MaesterSql -DbPath $DbPath -Query @"
        SELECT
            COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0) AS totalCompleted,
            COALESCE(SUM(CASE WHEN status = 'failed'    THEN 1 ELSE 0 END), 0) AS totalFailed,
            COALESCE(AVG(CASE WHEN status = 'completed' AND duration_ms > 0
                         THEN duration_ms END), 0)                              AS avgDurationMs,
            COALESCE(MIN(CASE WHEN status = 'completed' AND duration_ms > 0
                         THEN duration_ms END), 0)                              AS minDurationMs,
            COALESCE(MAX(CASE WHEN status = 'completed' AND duration_ms > 0
                         THEN duration_ms END), 0)                              AS maxDurationMs,
            MAX(completed_at)                                                    AS lastCompletedAt
        FROM job_stats
"@

    return [PSCustomObject]@{
        totalCompleted = [int]$row.totalCompleted
        totalFailed    = [int]$row.totalFailed
        avgDurationMs  = [math]::Round([double]$row.avgDurationMs)
        minDurationMs  = [int]$row.minDurationMs
        maxDurationMs  = [int]$row.maxDurationMs
        lastCompletedAt = if ($row.lastCompletedAt) { $row.lastCompletedAt } else { $null }
    }
}
