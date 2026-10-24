<#
.SYNOPSIS
    Prints the X++ call stack of one trace line (an SQL statement or a method call), outermost call first.

.DESCRIPTION
    Confirmed chain: the script follows ParentSequence from the line upward. Every frame found this way is a
    real caller.

    In batch and wave traces the chain can break: lock keep-alive threads (ReqReaderWriterLock...) and
    finalizers (Connection::finalize) are recorded in the same thread, so a ParentSequence can point at one of
    them. When that happens the script also lists the enclosing calls: X++ calls in the same thread whose
    [Sequence, SequenceEnd] range encloses the top of the confirmed chain. The real callers are among them,
    but so are calls that had already returned and only look open because a keep-alive call was recorded
    inside them. Names that occur 3 times or more in that list are such calls (lock helpers in a loop) and
    are collapsed into one summary line. Confirm the unconfirmed frames in the X++ source.

    Read-only: SELECT statements only, with Windows authentication.
    Exit codes: 0 = stack printed, 1 = trace line not found, 2 = setup or connection failure.

.EXAMPLE
    .\Get-TraceCallStack.ps1 -TraceLineId 2164639
.EXAMPLE
    .\Get-TraceCallStack.ps1 -TraceLineId 2164639 -ExcludeMethod 'ReqReaderWriterLock*','Connection::*','ABCLockManager::*'
#>
param(
    # TraceLineId from Find-TraceSql.ps1 or Find-TraceMethod.ps1.
    [Parameter(Mandatory = $true)]
    [long]$TraceLineId,

    # Method-name patterns (* wildcard) treated as noise: hidden, and they end the confirmed chain.
    [string[]]$ExcludeMethod = @('ReqReaderWriterLock*', 'ReqInstrumentationLoggerReqReaderWriterLock*', 'Connection::*', 'SysInstrumentation*'),

    [string]$Server = '.',

    # Trace Parser database. Default: the only database on the server that has the Trace Parser tables.
    [string]$Database = '',

    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TraceCommon.ps1')

# Patterns may arrive as one comma-separated string (powershell -File) or as an array.
$ExcludeMethod = @(($ExcludeMethod -join ',').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })

function Test-Noise([string]$name) {
    foreach ($p in $ExcludeMethod) { if ($name -like $p) { return $true } }
    return $false
}

$conn = Open-TraceConnection
try {
    $target = Invoke-TraceQuery $conn @"
SELECT tl.TraceLineId, tl.UserSessionProcessThreadId AS Thread, tl.Sequence, tl.ParentSequence,
       CAST(tl.InclusiveDurationNano / @ticksPerMs AS decimal(18, 1)) AS InclMs,
       COALESCE(mn.Name, LEFT(qs.Statement, 200)) AS Name
FROM dbo.TraceLines tl
LEFT JOIN dbo.MethodNames mn ON mn.MethodHash = tl.MethodHash
LEFT JOIN dbo.QueryStatements qs ON qs.QueryStatementHash = tl.QueryStatementHash AND tl.CallTypeId = 64
WHERE tl.TraceLineId = @line;
"@ @{ '@line' = $TraceLineId; '@ticksPerMs' = [decimal]$TraceTicksPerMs }
    if ($target.Rows.Count -eq 0) {
        Write-Output "Trace line $TraceLineId not found in '$Database'."
        $conn.Close()
        exit 1
    }
    $t = $target.Rows[0]

    # Every X++ call that encloses the line. A real caller always does, so the ParentSequence walk can use this set.
    $frames = Invoke-TraceQuery $conn @"
SELECT tl.TraceLineId, tl.Sequence, tl.ParentSequence,
       CAST(tl.InclusiveDurationNano / @ticksPerMs AS decimal(18, 1)) AS InclMs, mn.Name
FROM dbo.TraceLines tl
JOIN dbo.MethodNames mn ON mn.MethodHash = tl.MethodHash
WHERE tl.UserSessionProcessThreadId = @thread AND tl.CallTypeId = 8
  AND tl.Sequence < @seq AND tl.SequenceEnd >= @seq
ORDER BY tl.Sequence;
"@ @{ '@thread' = [int]$t['Thread']; '@seq' = [int]$t['Sequence']; '@ticksPerMs' = [decimal]$TraceTicksPerMs }
}
finally {
    $conn.Close()
}

$bySeq = @{}
foreach ($f in $frames.Rows) { $bySeq[[int]$f['Sequence']] = $f }

function New-Frame($row, [string]$name) {
    return @{ 'Line' = $row['TraceLineId']; 'Sequence' = [int]$row['Sequence']; 'Parent' = [int]$row['ParentSequence']; 'InclMs' = $row['InclMs']; 'Name' = $name }
}

# 1. Confirmed chain, innermost first.
$chain = New-Object System.Collections.Generic.List[object]
$chain.Add((New-Frame $t (Format-TraceValue $t['Name'])))
$cut = $null
$cur = $chain[0]
while ($cur['Parent'] -ne 0) {
    if (-not $bySeq.ContainsKey($cur['Parent'])) { $cut = "parent sequence $($cur['Parent']) is not an enclosing X++ call"; break }
    $p = $bySeq[$cur['Parent']]
    if (Test-Noise ([string]$p['Name'])) { $cut = "parent is $($p['Name']) (sequence $($p['Sequence']))"; break }
    $cur = New-Frame $p ([string]$p['Name'])
    $chain.Add($cur)
}
$chain.Reverse()

Write-Output "Call stack of trace line $TraceLineId (thread $($t['Thread']), sequence $($t['Sequence'])), outermost first."

# 2. When the chain is cut, the enclosing calls above its top frame.
if ($cut) {
    $top = $chain[0]['Sequence']
    $candidates = @($frames.Rows | Where-Object { [int]$_['Sequence'] -lt $top -and -not (Test-Noise ([string]$_['Name'])) })
    $counts = @{}
    foreach ($c in $candidates) { $n = [string]$c['Name']; if ($counts.ContainsKey($n)) { $counts[$n]++ } else { $counts[$n] = 1 } }
    $repeated = @($counts.Keys | Where-Object { $counts[$_] -ge 3 } | Sort-Object)
    Write-Output ''
    Write-Output "Enclosing calls (UNCONFIRMED: the parent chain breaks, $cut). The real callers are among them; some may have returned already. Check them in the X++ source."
    Write-Output "Sequence`tInclMs`tTraceLineId`tName"
    foreach ($c in $candidates) {
        if ($repeated -contains [string]$c['Name']) { continue }
        Write-Output "$($c['Sequence'])`t$($c['InclMs'])`t$($c['TraceLineId'])`t$($c['Name'])"
    }
    if ($repeated.Count -gt 0) {
        Write-Output ("Collapsed (3+ occurrences, returned calls that only look open): " + (($repeated | ForEach-Object { "$_ x$($counts[$_])" }) -join ', '))
    }
    Write-Output ''
    Write-Output 'Confirmed chain (each frame is the caller of the next):'
}
else {
    Write-Output 'Confirmed chain to the thread root (each frame is the caller of the next):'
}
Write-Output "Depth`tSequence`tInclMs`tTraceLineId`tName"
# Runs of 3+ identical consecutive frames (kernel recursion such as PropertyChange) are printed once.
$i = 0
while ($i -lt $chain.Count) {
    $j = $i
    while ($j + 1 -lt $chain.Count -and $chain[$j + 1]['Name'] -eq $chain[$i]['Name']) { $j++ }
    $name = $chain[$i]['Name']
    if ($j - $i + 1 -ge 3) { $name = "$name (x$($j - $i + 1) nested, depth $i..$j)" } else { $j = $i }
    Write-Output "$i`t$($chain[$i]['Sequence'])`t$($chain[$i]['InclMs'])`t$($chain[$i]['Line'])`t$name"
    $i = $j + 1
}
exit 0
