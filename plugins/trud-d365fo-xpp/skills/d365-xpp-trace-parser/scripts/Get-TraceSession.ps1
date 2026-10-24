<#
.SYNOPSIS
    Lists the traces imported into a Trace Parser database, or the sessions and busiest threads of one trace.

.DESCRIPTION
    Without -TraceId: one row per imported trace.
    With -TraceId: the trace's user sessions, then its threads ordered by number of trace lines, with the
    longest top-level X++ call of each thread. A batch job or wave run usually shows up as one thread that
    holds most of the lines, with a BatchRun method as its main call.

    Read-only: SELECT statements only, with Windows authentication.
    Exit codes: 0 = rows found, 1 = nothing found, 2 = setup or connection failure.

.EXAMPLE
    .\Get-TraceSession.ps1
.EXAMPLE
    .\Get-TraceSession.ps1 -TraceId 8 -Top 10
#>
param(
    [int]$TraceId = 0,

    # Number of threads to list for -TraceId.
    [int]$Top = 20,

    [string]$Server = '.',

    # Trace Parser database. Default: the only database on the server that has the Trace Parser tables.
    [string]$Database = '',

    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TraceCommon.ps1')

$conn = Open-TraceConnection
try {
    if ($TraceId -eq 0) {
        $traces = Invoke-TraceQuery $conn @"
SELECT t.TraceId, t.TraceName, t.TimeStampBegin, t.TimeStampEnd,
       (SELECT COUNT(*) FROM dbo.UserSessionProcessThreads p WHERE p.TraceId = t.TraceId) AS Threads
FROM dbo.Traces t
ORDER BY t.TraceId;
"@ @{}
        Write-Output "Traces in '$Database': $($traces.Rows.Count)"
        if ($traces.Rows.Count -eq 0) { exit 1 }
        Write-TraceRows $traces @('TraceId', 'TraceName', 'TimeStampBegin', 'TimeStampEnd', 'Threads')
        exit 0
    }

    # UserSessions is keyed by (SessionId, TraceId): session ids repeat in every trace.
    $sessions = Invoke-TraceQuery $conn @"
SELECT us.SessionId, us.SessionName, u.UserName,
       COUNT(DISTINCT p.UserSessionProcessThreadId) AS Threads
FROM dbo.UserSessions us
JOIN dbo.Users u ON u.UserId = us.UserId
JOIN dbo.UserSessionProcessThreads p ON p.SessionId = us.SessionId AND p.TraceId = us.TraceId
WHERE us.TraceId = @trace
GROUP BY us.SessionId, us.SessionName, u.UserName
ORDER BY us.SessionId;
"@ @{ '@trace' = $TraceId }

    $threads = Invoke-TraceQuery $conn @"
SELECT TOP (@top) x.Thread, x.SessionId, x.Lines, x.SqlLines, x.FirstSeq, x.LastSeq,
       CAST(f.InclusiveDurationNano / @ticksPerMs AS decimal(18, 1)) AS MainMs, f.Name AS MainMethod
FROM (
    SELECT p.UserSessionProcessThreadId AS Thread, p.SessionId,
           COUNT_BIG(*) AS Lines,
           SUM(CASE WHEN tl.CallTypeId = 64 THEN 1 ELSE 0 END) AS SqlLines,
           MIN(tl.Sequence) AS FirstSeq, MAX(tl.Sequence) AS LastSeq
    FROM dbo.UserSessionProcessThreads p
    JOIN dbo.TraceLines tl ON tl.UserSessionProcessThreadId = p.UserSessionProcessThreadId
    WHERE p.TraceId = @trace
    GROUP BY p.UserSessionProcessThreadId, p.SessionId
) x
OUTER APPLY (
    SELECT TOP 1 mn.Name, t1.InclusiveDurationNano
    FROM dbo.TraceLines t1
    JOIN dbo.MethodNames mn ON mn.MethodHash = t1.MethodHash
    WHERE t1.UserSessionProcessThreadId = x.Thread AND t1.CallTypeId = 8 AND t1.ParentSequence = 0
    ORDER BY t1.InclusiveDurationNano DESC
) f
ORDER BY x.Lines DESC;
"@ @{ '@trace' = $TraceId; '@top' = $Top; '@ticksPerMs' = [decimal]$TraceTicksPerMs }
}
finally {
    $conn.Close()
}

Write-Output "Trace $($TraceId): $($sessions.Rows.Count) session(s)"
if ($sessions.Rows.Count -eq 0) { exit 1 }
Write-TraceRows $sessions @('SessionId', 'SessionName', 'UserName', 'Threads')
Write-Output ''
Write-Output "Threads by number of trace lines (top $Top). Thread = UserSessionProcessThreadId, the value the other scripts take; MainMethod = its longest top-level X++ call."
Write-TraceRows $threads @('Thread', 'SessionId', 'Lines', 'SqlLines', 'FirstSeq', 'LastSeq', 'MainMs', 'MainMethod')
exit 0
