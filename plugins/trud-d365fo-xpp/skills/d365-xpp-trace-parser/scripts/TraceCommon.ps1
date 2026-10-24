# Shared helpers for the d365-xpp-trace-parser scripts: read-only SELECT queries against a Trace Parser
# database with Windows authentication. The calling script defines $Server, $Database and $TimeoutSeconds
# before it dot-sources this file.

# TraceLines.TimeStamp is a Windows FILETIME (100-ns ticks, UTC), and the *DurationNano columns use the same
# 100-ns unit despite their name: InclusiveDurationNano = TimeStampEnd - TimeStamp. 10,000 ticks = 1 ms.
$TraceTicksPerMs = 10000

# Without -Database, finds the databases on the server that have the Trace Parser tables and uses the only one.
function Find-TraceDatabase {
    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = "Server=$Server;Database=master;Integrated Security=SSPI;Application Name=d365-xpp-trace-parser"
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT d.name FROM sys.databases d WHERE d.state = 0 AND d.database_id > 4 AND HAS_DBACCESS(d.name) = 1 ORDER BY d.name"
        $names = New-Object System.Collections.Generic.List[string]
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) { $names.Add($reader.GetString(0)) }
        $reader.Close()
        $found = New-Object System.Collections.Generic.List[string]
        foreach ($n in $names) {
            $check = $conn.CreateCommand()
            $check.CommandText = "SELECT CASE WHEN OBJECT_ID(QUOTENAME(@db) + N'.dbo.TraceLines') IS NOT NULL AND OBJECT_ID(QUOTENAME(@db) + N'.dbo.QueryBindParameters') IS NOT NULL AND OBJECT_ID(QUOTENAME(@db) + N'.dbo.Traces') IS NOT NULL THEN 1 ELSE 0 END"
            [void]$check.Parameters.AddWithValue('@db', $n)
            if ([int]$check.ExecuteScalar() -eq 1) { $found.Add($n) }
        }
    }
    catch {
        Write-Output "ERROR: cannot list the databases on server '$Server': $($_.Exception.Message)"
        Write-Output "Pass -Database with the database the trace was imported into, and -Server if it is not the local default instance."
        exit 2
    }
    finally {
        $conn.Close()
    }
    if ($found.Count -eq 1) { return $found[0] }
    if ($found.Count -eq 0) {
        Write-Output "ERROR: no Trace Parser database found on server '$Server'. Import the trace in Trace Parser first, or pass -Database (and -Server)."
    }
    else {
        Write-Output "ERROR: several Trace Parser databases on server '$Server': $($found -join ', '). Pass -Database with the one that holds the trace."
    }
    exit 2
}

function Open-TraceConnection {
    if (-not $script:Database) { $script:Database = Find-TraceDatabase }
    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = "Server=$Server;Database=$($script:Database);Integrated Security=SSPI;Application Name=d365-xpp-trace-parser"
    try {
        $conn.Open()
    }
    catch {
        Write-Output "ERROR: cannot open database '$($script:Database)' on server '$Server': $($_.Exception.Message)"
        Write-Output "Pass -Database with the database the trace was imported into, and -Server if it is not the local default instance."
        exit 2
    }
    return $conn
}

# Runs a query and returns a DataTable. Values are passed as SQL parameters, never concatenated.
function Invoke-TraceQuery($conn, [string]$sql, [hashtable]$params) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SET NOCOUNT ON; " + $sql
    $cmd.CommandTimeout = $TimeoutSeconds
    if ($params) {
        foreach ($k in $params.Keys) {
            [void]$cmd.Parameters.AddWithValue($k, $params[$k])
        }
    }
    $table = New-Object System.Data.DataTable
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    try {
        [void]$adapter.Fill($table)
    }
    catch {
        Write-Output "ERROR: query failed: $($_.Exception.Message)"
        $conn.Close()
        exit 2
    }
    return ,$table
}

# Keeps a value on one tab-separated line.
function Format-TraceValue($value) {
    if ($null -eq $value -or $value -is [System.DBNull]) { return '' }
    return ("$value" -replace "[`t`r`n]+", ' ')
}

function Write-TraceRows($table, [string[]]$columns) {
    Write-Output ($columns -join "`t")
    foreach ($row in $table.Rows) {
        Write-Output (($columns | ForEach-Object { Format-TraceValue $row[$_] }) -join "`t")
    }
}

# Turns a * wildcard pattern into a LIKE pattern (escapes [ and _ first).
function ConvertTo-TraceLike([string]$text) {
    return $text.Replace('[', '[[]').Replace('_', '[_]').Replace('*', '%')
}

function Add-ParameterName([hashtable]$map, [string]$key, [int]$index) {
    if (-not $map.ContainsKey($key)) { $map[$key] = $index; return $key }
    $n = 2
    while ($map.ContainsKey("$key#$n")) { $n++ }
    $map["$key#$n"] = $index
    return "$key#$n"
}

# Names the bind parameters of an SQL statement. Parameter positions follow the order of the ? placeholders.
#   INSERT ... VALUES   the column list
#   INSERT ... SELECT   (insert_recordset) the n-th SELECT item feeds the n-th insert column
#   anything else       the column compared with the ?, e.g. SET WORKSTATUS=? or WHERE T1.ITEMID=?
# A repeated column gets COLUMN#2, #3...; an aliased one is also reachable as T2.COLUMN.
# Returns @{ Map = NAME -> 0-based index; Names = display name per index ('?n' if unnamed); Count = number of ? }.
function Get-ParameterMap([string]$statement) {
    $map = @{}
    $qs = [regex]::Matches($statement, '\?')
    $names = New-Object string[] $qs.Count
    for ($i = 0; $i -lt $qs.Count; $i++) { $names[$i] = "?$i" }

    $m = [regex]::Match($statement, '^\s*INSERT\s+INTO\s+\S+\s*\(([^)]*)\)\s*(VALUES\s*\(|SELECT\s)', 'IgnoreCase')
    $insertCols = @()
    if ($m.Success) { $insertCols = @($m.Groups[1].Value.Split(',') | ForEach-Object { $_.Trim().ToUpperInvariant() }) }

    if ($m.Success -and $m.Groups[2].Value.ToUpperInvariant().StartsWith('VALUES')) {
        for ($i = 0; $i -lt $qs.Count -and $i -lt $insertCols.Count; $i++) {
            $names[$i] = Add-ParameterName $map $insertCols[$i] $i
        }
        return @{ 'Map' = $map; 'Names' = $names; 'Count' = $qs.Count }
    }

    # insert_recordset: where each top-level SELECT item starts, up to the first top-level FROM.
    $itemStarts = @()
    $selEnd = -1
    if ($m.Success) {
        $selStart = $m.Index + $m.Length
        $itemStarts = @($selStart)
        $fromRegex = New-Object System.Text.RegularExpressions.Regex('\G\s+FROM\s', 'IgnoreCase')
        $depth = 0
        for ($p = $selStart; $p -lt $statement.Length; $p++) {
            $ch = $statement[$p]
            if ($ch -eq '(') { $depth++ }
            elseif ($ch -eq ')') { $depth-- }
            elseif ($depth -eq 0 -and $ch -eq ',') { $itemStarts += ($p + 1) }
            elseif ($depth -eq 0 -and $fromRegex.Match($statement, $p).Success) { $selEnd = $p; break }
        }
        if ($selEnd -lt 0) { $selEnd = $statement.Length }
    }

    $colRegex = New-Object System.Text.RegularExpressions.Regex('((?:[A-Za-z0-9_]+\.)?[A-Za-z0-9_]+)\s*(=|<>|!=|>=|<=|>|<|\bLIKE)\s*$', 'IgnoreCase')
    for ($i = 0; $i -lt $qs.Count; $i++) {
        $pos = $qs[$i].Index
        if ($itemStarts.Count -gt 0 -and $pos -lt $selEnd) {
            $k = @($itemStarts | Where-Object { $_ -le $pos }).Count - 1
            if ($k -ge 0 -and $k -lt $insertCols.Count) { $names[$i] = Add-ParameterName $map $insertCols[$k] $i }
            continue
        }
        $c = $colRegex.Match($statement.Substring(0, $pos))
        if ($c.Success) {
            $full = $c.Groups[1].Value.ToUpperInvariant()
            $short = ($full -split '\.')[-1]
            $names[$i] = Add-ParameterName $map $short $i
            if ($full -ne $short -and -not $map.ContainsKey($full)) { $map[$full] = $i }
        }
    }
    return @{ 'Map' = $map; 'Names' = $names; 'Count' = $qs.Count }
}

# First word of the statement (INSERT, UPDATE, DELETE, SELECT...) and the table it writes or reads first.
function Get-StatementTarget([string]$statement) {
    $op = ($statement.Trim() -split '\s+')[0].ToUpperInvariant()
    $m = [regex]::Match($statement, '^\s*(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(\S+)', 'IgnoreCase')
    if (-not $m.Success) { $m = [regex]::Match($statement, '\sFROM\s+(\S+)', 'IgnoreCase') }
    $table = ''
    if ($m.Success) { $table = $m.Groups[1].Value.ToUpperInvariant() }
    return @{ 'Op' = $op; 'Table' = $table }
}
