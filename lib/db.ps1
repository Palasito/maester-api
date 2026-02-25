# lib/db.ps1 — SQLite data access helpers for Maester job persistence
#
# All database operations go through this module. Uses PSSQLite for
# parameterised queries (SQL-injection safe) against a file-based
# SQLite database with WAL mode for concurrent read/write safety.
#
# ─── Usage ───────────────────────────────────────────────────────
# . /app/lib/db.ps1                         # dot-source in server.ps1
# Initialize-MaesterDb -DbPath $DB_PATH     # create table + WAL mode
# New-MaesterJob -DbPath $DB_PATH -JobId $id -Suites @('maester') -Severity @('High')
# ─────────────────────────────────────────────────────────────────

# ── Initialise database & schema ──────────────────────────────────────────────

function Initialize-MaesterDb {
    <#
    .SYNOPSIS  Create the jobs table (idempotent) and enable WAL journal mode.
    #>
    param([Parameter(Mandatory)][string]$DbPath)

    Invoke-SqliteQuery -DataSource $DbPath -Query @"
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
        Invoke-SqliteQuery -DataSource $DbPath -Query 'ALTER TABLE jobs ADD COLUMN tenant_id TEXT NOT NULL DEFAULT "";' -ErrorAction Stop
    } catch {
        # Column already exists — safe to ignore
    }

    # Persistent statistics table — survives job deletion
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
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
    Invoke-SqliteQuery -DataSource $DbPath -Query 'PRAGMA journal_mode=WAL;'
    # Wait up to 5 s for a write lock instead of failing immediately
    Invoke-SqliteQuery -DataSource $DbPath -Query 'PRAGMA busy_timeout=5000;'
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
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        INSERT INTO jobs (job_id, status, created_at, updated_at, suites, severity)
        VALUES (@jobId, 'running', @now, @now, @suites, @severity)
"@ -SqlParameters @{
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

    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        SELECT * FROM jobs WHERE job_id = @jobId
"@ -SqlParameters @{ jobId = $JobId }
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
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        UPDATE jobs
        SET    status      = @status,
               updated_at  = @now,
               result      = @result,
               error       = @errorMsg,
               duration_ms = @durationMs
        WHERE  job_id      = @jobId
"@ -SqlParameters @{
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

    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        DELETE FROM jobs WHERE job_id = @jobId
"@ -SqlParameters @{ jobId = $JobId }
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
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        DELETE FROM jobs WHERE created_at < @cutoff
"@ -SqlParameters @{ cutoff = $hardCutoff }

    # Soft: remove terminal-state jobs past the completed timeout
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        DELETE FROM jobs
        WHERE  status IN ('completed', 'failed')
          AND  updated_at < @cutoff
"@ -SqlParameters @{ cutoff = $completedCutoff }
}

function Get-RunningJobCount {
    <#
    .SYNOPSIS  Return the number of jobs currently in 'running' state.
    #>
    param([Parameter(Mandatory)][string] $DbPath)

    $row = Invoke-SqliteQuery -DataSource $DbPath -Query @"
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

    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        UPDATE jobs
        SET    status     = 'failed',
               error      = 'Job timed out (stale detection). Container may have restarted.',
               updated_at = @now
        WHERE  status = 'running'
          AND  created_at < @cutoff
"@ -SqlParameters @{ cutoff = $cutoff; now = $now }
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
    Invoke-SqliteQuery -DataSource $DbPath -Query @"
        INSERT INTO job_stats (job_id, status, duration_ms, suites, completed_at)
        VALUES (@jobId, @status, @durationMs, @suites, @now)
"@ -SqlParameters @{
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

    $row = Invoke-SqliteQuery -DataSource $DbPath -Query @"
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
