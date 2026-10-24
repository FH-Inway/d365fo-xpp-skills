<#
.SYNOPSIS
    Lists the X++ methods of a trace that match a name pattern, in the order they first ran, with call counts,
    first and last sequence and total time.

.DESCRIPTION
    Use it to see which methods of a class or feature ran in a thread and in what order, for example every
    '*Template*' method or every 'SalesFormLetter::*' method. FirstSeq/LastSeq are sequence numbers in the
    thread, so they also show which calls happened inside another call (its Sequence..SequenceEnd range).
    With -Name matching one method, -Calls lists each call (TraceLineId, sequence, time) instead.

    Read-only: SELECT statements only, with Windows authentication.
    Exit codes: 0 = rows found, 1 = nothing found, 2 = setup or connection failure.

.EXAMPLE
    .\Find-TraceMethod.ps1 -TraceId 8 -Thread 419 -Name '*Template*'
.EXAMPLE
    .\Find-TraceMethod.ps1 -TraceId 8 -Name 'WhsWorkCreate::processTempTable' -Calls
#>
param(
    [Parameter(Mandatory = $true)]
    [int]$TraceId,

    # Method-name pattern, Class::method, * wildcard. Example: 'WhsWorkCreate::*'.
    [Parameter(Mandatory = $true)]
    [string]$Name,

    # Method-name patterns to leave out. Getters/setters (parm methods) by default.
    [string[]]$ExcludeName = @('*::parm*'),

    # Only this thread (UserSessionProcessThreadId from Get-TraceSession.ps1).
    [int]$Thread = 0,

    # One row per call instead of one row per method.
    [switch]$Calls,

    [int]$Top = 300,

    [string]$Server = '.',

    # Trace Parser database. Default: the only database on the server that has the Trace Parser tables.
    [string]$Database = '',

    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TraceCommon.ps1')

$params = @{ '@trace' = $TraceId; '@name' = (ConvertTo-TraceLike $Name); '@thread' = $Thread; '@top' = $Top; '@ticksPerMs' = [decimal]$TraceTicksPerMs }
$where = 'p.TraceId = @trace AND tl.CallTypeId = 8 AND mn.Name LIKE @name'
if ($Thread -ne 0) { $where += ' AND tl.UserSessionProcessThreadId = @thread' }
$i = 0
# Patterns may arrive as one comma-separated string (powershell -File) or as an array.
foreach ($x in ($ExcludeName -join ',').Split(',')) {
    $x = $x.Trim()
    if ($x) {
        $where += " AND mn.Name NOT LIKE @ex$i"
        $params["@ex$i"] = ConvertTo-TraceLike $x
        $i++
    }
}
$from = @"
FROM dbo.TraceLines tl
JOIN dbo.UserSessionProcessThreads p ON p.UserSessionProcessThreadId = tl.UserSessionProcessThreadId
JOIN dbo.MethodNames mn ON mn.MethodHash = tl.MethodHash
WHERE $where
"@

$conn = Open-TraceConnection
try {
    if ($Calls) {
        $rows = Invoke-TraceQuery $conn @"
SELECT TOP (@top) tl.TraceLineId, tl.UserSessionProcessThreadId AS Thread, tl.Sequence, tl.SequenceEnd,
       CAST(tl.InclusiveDurationNano / @ticksPerMs AS decimal(18, 1)) AS InclMs, tl.DatabaseCalls, mn.Name
$from
ORDER BY tl.UserSessionProcessThreadId, tl.Sequence;
"@ $params
        $columns = @('TraceLineId', 'Thread', 'Sequence', 'SequenceEnd', 'InclMs', 'DatabaseCalls', 'Name')
    }
    else {
        $rows = Invoke-TraceQuery $conn @"
SELECT TOP (@top) tl.UserSessionProcessThreadId AS Thread, COUNT_BIG(*) AS Calls,
       MIN(tl.Sequence) AS FirstSeq, MAX(tl.Sequence) AS LastSeq,
       CAST(SUM(tl.InclusiveDurationNano) / @ticksPerMs AS decimal(18, 1)) AS TotalMs, mn.Name
$from
GROUP BY tl.UserSessionProcessThreadId, mn.Name
ORDER BY tl.UserSessionProcessThreadId, MIN(tl.Sequence);
"@ $params
        $columns = @('Thread', 'Calls', 'FirstSeq', 'LastSeq', 'TotalMs', 'Name')
    }
}
finally {
    $conn.Close()
}

$what = 'Methods'
if ($Calls) { $what = 'Calls of methods' }
Write-Output "$what like '$Name' in trace $TraceId$(if ($Thread) { " thread $Thread" }): $($rows.Rows.Count) row(s)$(if ($rows.Rows.Count -ge $Top) { " (limited by -Top $Top)" }). TotalMs of nested or recursive calls overlaps."
if ($rows.Rows.Count -eq 0) { exit 1 }
Write-TraceRows $rows $columns
exit 0
