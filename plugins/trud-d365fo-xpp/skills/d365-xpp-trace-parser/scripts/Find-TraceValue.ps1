<#
.SYNOPSIS
    Searches the SQL bind values of a trace for a value and reports where it was used: table, column,
    statement, number of calls, and the first call (trace line).

.DESCRIPTION
    Answers "which code wrote (or read) WORK-000123 / item A0001 / RecId 5637144576?" without knowing the
    table: every SQL call's bind values are searched. Each hit is named with the column the value was bound
    to (see Find-TraceSql.ps1 for the naming rules). Pass the first TraceLineId to Get-TraceCallStack.ps1 to
    see which X++ code ran the statement.

    Values exist only if the trace was captured with SQL parameter values. Values the kernel puts into the
    SQL text as literals (often DATAAREAID and PARTITION) are not bind values and are not found here.

    Read-only: SELECT statements only, with Windows authentication.
    Exit codes: 0 = rows found, 1 = nothing found, 2 = setup or connection failure.

.EXAMPLE
    .\Find-TraceValue.ps1 -TraceId 8 -Value 'WORK-000123'
.EXAMPLE
    .\Find-TraceValue.ps1 -TraceId 8 -Value 'PICK*' -Operation Write
#>
param(
    [Parameter(Mandatory = $true)]
    [int]$TraceId,

    # Exact value, or a pattern with * wildcards.
    [Parameter(Mandatory = $true)]
    [string]$Value,

    # Write = INSERT, UPDATE and DELETE statements only.
    [ValidateSet('Any', 'Write', 'Insert', 'Update', 'Delete', 'Select')]
    [string]$Operation = 'Any',

    # Only this thread (UserSessionProcessThreadId from Get-TraceSession.ps1).
    [int]$Thread = 0,

    [int]$Top = 200,

    [string]$Server = '.',

    # Trace Parser database. Default: the only database on the server that has the Trace Parser tables.
    [string]$Database = '',

    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TraceCommon.ps1')

$params = @{ '@trace' = $TraceId; '@thread' = $Thread; '@top' = $Top }
if ($Value.Contains('*')) {
    $valueWhere = 'b.BindValue LIKE @value'
    $params['@value'] = ConvertTo-TraceLike $Value
}
else {
    $valueWhere = 'b.BindValue = @value'
    $params['@value'] = $Value
}
$opWhere = ''
switch ($Operation) {
    'Write'  { $opWhere = " AND (qs.Statement LIKE 'INSERT %' OR qs.Statement LIKE 'UPDATE %' OR qs.Statement LIKE 'DELETE %')" }
    'Insert' { $opWhere = " AND qs.Statement LIKE 'INSERT %'" }
    'Update' { $opWhere = " AND qs.Statement LIKE 'UPDATE %'" }
    'Delete' { $opWhere = " AND qs.Statement LIKE 'DELETE %'" }
    'Select' { $opWhere = " AND qs.Statement LIKE 'SELECT %'" }
}
$threadWhere = ''
if ($Thread -ne 0) { $threadWhere = ' AND tl.UserSessionProcessThreadId = @thread' }

$conn = Open-TraceConnection
try {
    $rows = Invoke-TraceQuery $conn @"
SELECT TOP (@top) tl.QueryStatementHash, b.ParameterIndex, COUNT_BIG(*) AS Calls,
       COUNT(DISTINCT tl.UserSessionProcessThreadId) AS Threads,
       MIN(tl.TraceLineId) AS FirstTraceLineId, MIN(tl.Sequence) AS FirstSeq,
       MIN(b.BindValue) AS SampleValue, MIN(qs.Statement) AS Statement
FROM dbo.QueryBindParameters b
JOIN dbo.TraceLines tl ON tl.TraceLineId = b.TraceLineId AND tl.CallTypeId = 64
JOIN dbo.UserSessionProcessThreads p ON p.UserSessionProcessThreadId = tl.UserSessionProcessThreadId AND p.TraceId = @trace
JOIN dbo.QueryStatements qs ON qs.QueryStatementHash = tl.QueryStatementHash
WHERE $valueWhere $threadWhere $opWhere
GROUP BY tl.QueryStatementHash, b.ParameterIndex
ORDER BY MIN(tl.Sequence);
"@ $params
}
finally {
    $conn.Close()
}

Write-Output "Value '$Value' in $Operation statements of trace $TraceId$(if ($Thread) { " thread $Thread" }): $($rows.Rows.Count) statement/parameter pair(s)$(if ($rows.Rows.Count -ge $Top) { " (limited by -Top $Top)" }). FirstTraceLineId = lowest trace line of those calls, for Get-TraceCallStack.ps1."
if ($rows.Rows.Count -eq 0) { exit 1 }
Write-Output "Op`tTable`tColumn`tCalls`tThreads`tFirstSeq`tFirstTraceLineId`tStatementHash`tValue"
foreach ($r in $rows.Rows) {
    $statement = [string]$r['Statement']
    $target = Get-StatementTarget $statement
    $pm = Get-ParameterMap $statement
    $i = [int]$r['ParameterIndex']
    $column = "?$i"
    if ($i -lt $pm['Count']) { $column = $pm['Names'][$i] }
    Write-Output "$($target['Op'])`t$($target['Table'])`t$column`t$($r['Calls'])`t$($r['Threads'])`t$($r['FirstSeq'])`t$($r['FirstTraceLineId'])`t$($r['QueryStatementHash'])`t$(Format-TraceValue $r['SampleValue'])"
}
exit 0
