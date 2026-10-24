<#
.SYNOPSIS
    Finds the SQL statements a trace ran against a table and, with -Columns, the actual values each call
    bound to those columns (for example the WORKTEMPLATECODE of every inserted WHSWORKTABLE record).

.DESCRIPTION
    Without -Columns: one row per distinct statement on the table, with the number of calls in the trace.
    With -Columns: one row per call (trace line) with the bind values of the requested columns.
    With -Columns *: one row per call with every parameter as NAME=value.

    Bind values are stored per SQL trace line (CallTypeId 64) in QueryBindParameters, by 0-based parameter
    position, which follows the order of the ? placeholders in the statement text. The script names each
    position:
      INSERT ... VALUES   the column list
      INSERT ... SELECT   (insert_recordset) the n-th SELECT item feeds the n-th insert column
      anything else       the column compared with the ?, e.g. SET WORKSTATUS=? or WHERE T1.ITEMID=?
    A column used twice gets a second name: T2.ITEMID for another table alias, RECVERSION#2 for a repeat.
    Values exist only if the trace was captured with SQL parameter values.

    Read-only: SELECT statements only, with Windows authentication.
    Exit codes: 0 = rows found, 1 = nothing found, 2 = setup or connection failure.

.EXAMPLE
    .\Find-TraceSql.ps1 -TraceId 8 -Table WHSWORKTABLE
.EXAMPLE
    .\Find-TraceSql.ps1 -TraceId 8 -Table WHSWORKTABLE -Operation Insert -Columns WAVEID,WORKID,WORKTEMPLATECODE -Filter 'WAVEID=WAVE-0001'
.EXAMPLE
    .\Find-TraceSql.ps1 -TraceId 8 -Table WHSWORKTABLE -Operation Update -Columns * -Thread 419 -Top 20
#>
param(
    [Parameter(Mandatory = $true)]
    [int]$TraceId,

    # Physical table name as it appears in the SQL text, e.g. WHSWORKTABLE (case-insensitive).
    [Parameter(Mandatory = $true)]
    [string]$Table,

    # Write = Insert, Update and Delete.
    [ValidateSet('Write', 'Insert', 'Update', 'Delete', 'Select', 'Any')]
    [string]$Operation = 'Write',

    # Columns whose bound values to print, e.g. WAVEID,WORKID, or * for all. Omit to list the statements only.
    [string[]]$Columns,

    # Keep only calls whose values match, e.g. 'WAVEID=WAVE-0001' or 'ITEMID=A*;WORKTYPE=1' (* wildcard, ; between
    # conditions). A statement that doesn't bind a filter column is skipped, so 'COL=*' keeps statements that set COL.
    [string]$Filter,

    # Only this thread (UserSessionProcessThreadId from Get-TraceSession.ps1).
    [int]$Thread = 0,

    # Only this statement (QueryStatementHash from the statement list).
    [long]$StatementHash = 0,

    [int]$Top = 500,

    [string]$Server = '.',

    # Trace Parser database. Default: the only database on the server that has the Trace Parser tables.
    [string]$Database = '',

    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TraceCommon.ps1')

$tableLike = ConvertTo-TraceLike $Table.Trim().ToUpperInvariant()
$conditions = @{
    'Insert' = "qs.Statement LIKE 'INSERT INTO ' + @table + ' %'"
    'Update' = "qs.Statement LIKE 'UPDATE ' + @table + ' %'"
    'Delete' = "qs.Statement LIKE 'DELETE FROM ' + @table + ' %'"
    'Select' = "(qs.Statement LIKE 'SELECT %' AND (qs.Statement LIKE '% FROM ' + @table + ' %' OR qs.Statement LIKE '% JOIN ' + @table + ' %'))"
}
switch ($Operation) {
    'Write' { $opWhere = '(' + (@($conditions['Insert'], $conditions['Update'], $conditions['Delete']) -join ' OR ') + ')' }
    'Any'   { $opWhere = '(' + (@($conditions['Insert'], $conditions['Update'], $conditions['Delete'], $conditions['Select']) -join ' OR ') + ')' }
    default { $opWhere = $conditions[$Operation] }
}
$extra = ''
if ($Thread -ne 0) { $extra += ' AND tl.UserSessionProcessThreadId = @thread' }
if ($StatementHash -ne 0) { $extra += ' AND qs.QueryStatementHash = @hash' }
$params = @{ '@trace' = $TraceId; '@table' = $tableLike; '@thread' = $Thread; '@hash' = $StatementHash }

# -Columns may arrive as one comma-separated string (powershell -File) or as an array.
$wanted = New-Object System.Collections.Generic.List[string]
$allColumns = $false
foreach ($c in ($Columns -join ',').Split(',')) {
    $n = $c.Trim().ToUpperInvariant()
    if ($n -eq '*') { $allColumns = $true }
    elseif ($n -and -not $wanted.Contains($n)) { $wanted.Add($n) }
}
$filters = @()
if ($Filter) {
    foreach ($f in $Filter.Split(';')) {
        if (-not $f.Trim()) { continue }
        $pos = $f.IndexOf('=')
        if ($pos -lt 1) { Write-Output "ERROR: -Filter '$f' must look like COLUMN=value"; exit 2 }
        $n = $f.Substring(0, $pos).Trim().ToUpperInvariant()
        $filters += , @($n, $f.Substring($pos + 1).Trim())
        if (-not $allColumns -and -not $wanted.Contains($n)) { $wanted.Add($n) }
    }
}
$listOnly = (-not $allColumns) -and ($wanted.Count -eq 0)

$conn = Open-TraceConnection
try {
    $statements = Invoke-TraceQuery $conn @"
SELECT qs.QueryStatementHash, COUNT_BIG(*) AS Calls, MIN(tl.Sequence) AS FirstSeq, MIN(qs.Statement) AS Statement
FROM dbo.QueryStatements qs
JOIN dbo.TraceLines tl ON tl.QueryStatementHash = qs.QueryStatementHash AND tl.CallTypeId = 64
JOIN dbo.UserSessionProcessThreads p ON p.UserSessionProcessThreadId = tl.UserSessionProcessThreadId AND p.TraceId = @trace
WHERE $opWhere $extra
GROUP BY qs.QueryStatementHash
ORDER BY MIN(tl.Sequence);
"@ $params

    if ($statements.Rows.Count -eq 0) {
        Write-Output "No $Operation statements on '$Table' in trace $TraceId$(if ($Thread) { " thread $Thread" }). Check the physical table name (Get-TraceSession.ps1 lists traces; a TempDB table has a generated name)."
        $conn.Close()
        exit 1
    }

    if ($listOnly) {
        $conn.Close()
        Write-Output "$Operation statements on '$Table' in trace $($TraceId)$(if ($Thread) { " thread $Thread" }): $($statements.Rows.Count)"
        Write-Output "StatementHash`tCalls`tFirstSeq`tStatement"
        foreach ($s in $statements.Rows) {
            $text = Format-TraceValue $s['Statement']
            if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + ' ...' }
            Write-Output "$($s['QueryStatementHash'])`t$($s['Calls'])`t$($s['FirstSeq'])`t$text"
        }
        exit 0
    }

    $out = New-Object System.Collections.Generic.List[string]
    $total = 0
    $countMismatch = 0
    foreach ($s in $statements.Rows) {
        $statement = [string]$s['Statement']
        $pm = Get-ParameterMap $statement
        $map = $pm['Map']
        $op = ($statement.Trim() -split '\s+')[0].ToUpperInvariant()
        if (@($filters | Where-Object { -not $map.ContainsKey($_[0]) }).Count -gt 0) {
            continue   # a filter column isn't bound in this statement
        }
        if ($allColumns) {
            $indexes = @(0..([Math]::Max(0, $pm['Count'] - 1)))
            if ($pm['Count'] -eq 0) { $indexes = @() }
        }
        else {
            $indexes = @($wanted | Where-Object { $map.ContainsKey($_) } | ForEach-Object { [int]$map[$_] })
        }
        $bindJoin = ''
        $selectBind = ''
        if ($indexes.Count -gt 0) {
            $bindJoin = "LEFT JOIN dbo.QueryBindParameters b ON b.TraceLineId = tl.TraceLineId AND b.ParameterIndex IN ($(($indexes | Sort-Object -Unique) -join ','))"
            $selectBind = ', b.ParameterIndex, b.BindValue'
        }
        $threadWhere = ''
        if ($Thread -ne 0) { $threadWhere = ' AND tl.UserSessionProcessThreadId = @thread' }
        $calls = Invoke-TraceQuery $conn @"
SELECT tl.TraceLineId, tl.UserSessionProcessThreadId AS Thread, tl.Sequence,
       (SELECT COUNT(*) FROM dbo.QueryBindParameters bc WHERE bc.TraceLineId = tl.TraceLineId) AS BindCount $selectBind
FROM dbo.TraceLines tl
JOIN dbo.UserSessionProcessThreads p ON p.UserSessionProcessThreadId = tl.UserSessionProcessThreadId AND p.TraceId = @trace
$bindJoin
WHERE tl.QueryStatementHash = @hash AND tl.CallTypeId = 64 $threadWhere
ORDER BY tl.UserSessionProcessThreadId, tl.Sequence;
"@ @{ '@trace' = $TraceId; '@thread' = $Thread; '@hash' = [long]$s['QueryStatementHash'] }

        # One record per trace line: parameter index -> value.
        $byLine = [ordered]@{}
        foreach ($r in $calls.Rows) {
            $key = [string]$r['TraceLineId']
            if (-not $byLine.Contains($key)) {
                $byLine[$key] = @{ 'Thread' = $r['Thread']; 'Sequence' = $r['Sequence']; 'BindCount' = [int]$r['BindCount']; 'Values' = @{} }
            }
            if ($selectBind -and -not ($r['ParameterIndex'] -is [System.DBNull])) {
                $byLine[$key]['Values'][[int]$r['ParameterIndex']] = Format-TraceValue $r['BindValue']
            }
        }
        foreach ($key in $byLine.Keys) {
            $rec = $byLine[$key]
            $ok = $true
            foreach ($f in $filters) {
                $i = [int]$map[$f[0]]
                $v = ''
                if ($rec['Values'].ContainsKey($i)) { $v = $rec['Values'][$i] }
                if (-not ($v -like $f[1])) { $ok = $false }
            }
            if (-not $ok) { continue }
            $total++
            $flag = ''
            if ($rec['BindCount'] -gt 0 -and $rec['BindCount'] -ne $pm['Count']) { $flag = '!'; $countMismatch++ }
            if ($out.Count -ge $Top) { continue }
            if ($allColumns) {
                $pairs = @()
                for ($i = 0; $i -lt $pm['Count']; $i++) {
                    $v = ''
                    if ($rec['Values'].ContainsKey($i)) { $v = $rec['Values'][$i] }
                    $pairs += "$($pm['Names'][$i])=$v"
                }
                $vals = @($pairs -join ' | ')
            }
            else {
                $vals = @($wanted | ForEach-Object {
                    if ($map.ContainsKey($_)) {
                        $i = [int]$map[$_]
                        if ($rec['Values'].ContainsKey($i)) { $rec['Values'][$i] } else { '' }
                    }
                    else { '-' }
                })
            }
            $line = @($key, $rec['Thread'], $rec['Sequence'], "$op$flag", $s['QueryStatementHash']) + $vals
            $out.Add(($line | ForEach-Object { "$_" }) -join "`t")
        }
    }
}
finally {
    $conn.Close()
}

$limited = ''
if ($total -gt $out.Count) { $limited = " (showing $($out.Count), raise -Top)" }
Write-Output "Calls on '$Table' in trace $TraceId$(if ($Thread) { " thread $Thread" })$(if ($Filter) { " where $Filter" }): $total$limited. '-' = column not bound by that statement."
if ($countMismatch -gt 0) {
    Write-Output "WARNING: $countMismatch call(s), marked ! in Op, captured a different number of values than the statement has ? placeholders: their column mapping may be wrong."
}
if ($total -eq 0) { exit 1 }
$valueHeader = @($wanted)
if ($allColumns) { $valueHeader = @('Parameters') }
Write-Output ((@('TraceLineId', 'Thread', 'Sequence', 'Op', 'StatementHash') + $valueHeader) -join "`t")
$out | ForEach-Object { Write-Output $_ }
exit 0
