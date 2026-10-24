# Trace Parser database schema (for ad-hoc queries)

Read this when the scripts don't answer the question and you need to query the trace database directly. All queries are read-only; always filter by `TraceId` through `UserSessionProcessThreads`.

## Tables

| Table | Key columns | Notes |
|---|---|---|
| `Traces` | `TraceId`, `TraceName`, `TimeStampBegin`, `TimeStampEnd` | One row per imported trace. |
| `UserSessions` | `SessionId` + `TraceId`, `UserId`, `SessionName` | Session ids repeat in every trace: join on both columns. |
| `Users` | `UserId`, `UserName` | |
| `UserSessionProcessThreads` | `UserSessionProcessThreadId`, `SessionId`, `TraceId` | One row per thread of a session. Its id is the "thread" every other table uses. |
| `TraceLines` | `TraceLineId`, `UserSessionProcessThreadId`, `Sequence`, `SequenceEnd`, `ParentSequence`, `CallTypeId`, `MethodHash`, `QueryStatementHash`, `TimeStamp`, `TimeStampEnd`, `InclusiveDurationNano`, `ExclusiveDurationNano`, `DatabaseDurationNano`, `DatabaseCalls`, `RowFetchCount`, `HasChildren`, `EventName` | One row per X++ call, SQL statement or event. |
| `MethodNames` | `MethodHash`, `Name` | `Class::method`, `Forms.<Form>+<Control>::method`, or kernel names (`FormRun::init`, `PropertyChange::::::`). |
| `QueryStatements` | `QueryStatementHash`, `Statement` | The SQL text with `?` placeholders. |
| `QueryBindParameters` | `TraceLineId`, `ParameterIndex` (0-based), `BindValue` (text) | The bound values of one SQL call, by `?` position. |
| `QueryTables` | `QueryTableHash`, `TableNames` | Tables of a statement (`TraceLines.QueryTableHash`). |
| `Messages` | `MessageHash`, `MessageText` | Text of kernel events (`TraceLines.MessageHash`, mostly `CallTypeId` 8192 and 0): session handling, database access, forms engine, reflection. Not the infolog. |

Useful indexes: `TraceLines (UserSessionProcessThreadId, Sequence)` is unique; there are also indexes on `(UserSessionProcessThreadId, ParentSequence)`, `(…, QueryStatementHash)` and `(…, MethodHash)`. Queries that filter by thread are fast.

## Column meanings

- **`CallTypeId`:** `8` = X++ method, `64` = SQL statement (the line that has the bind values), `8192` = kernel event (`EventName` such as "Database access related.", text in `Messages`). Other values (0, 32, 128) occur but aren't needed for code analysis.
- **`Sequence`:** a counter over the whole trace, unique and in time order across threads. `SequenceEnd` is the last sequence inside the call, so a call encloses every line with `Sequence` between its `Sequence` and `SequenceEnd` in the same thread.
- **`ParentSequence`:** the `Sequence` of the calling line in the same thread, `0` for a thread root. Unreliable in batch traces with lock keep-alive threads (see the skill's Gotchas).
- **Times:** `TimeStamp`/`TimeStampEnd` are Windows FILETIME values (100-ns ticks since 1601, UTC); `TimeStampEnd` can be `0` for a call that was still open when the trace stopped. The `*DurationNano` columns are 100-ns ticks too: divide by 10,000 for milliseconds. Convert a timestamp in PowerShell with `[DateTime]::FromFileTimeUtc(<value>)`.

## Query patterns

Everything one thread did between two sequence numbers (for example between two statements found with the scripts):

```sql
SELECT tl.Sequence, tl.ParentSequence, tl.CallTypeId, CAST(tl.InclusiveDurationNano / 10000.0 AS decimal(18,1)) AS InclMs,
       COALESCE(mn.Name, LEFT(qs.Statement, 200)) AS What
FROM dbo.TraceLines tl
LEFT JOIN dbo.MethodNames mn ON mn.MethodHash = tl.MethodHash
LEFT JOIN dbo.QueryStatements qs ON qs.QueryStatementHash = tl.QueryStatementHash AND tl.CallTypeId = 64
WHERE tl.UserSessionProcessThreadId = @thread AND tl.Sequence BETWEEN @fromSeq AND @toSeq
  AND tl.CallTypeId IN (8, 64)
ORDER BY tl.Sequence;
```

Direct children of one call (what a method called, in order):

```sql
SELECT tl.Sequence, tl.TraceLineId, CAST(tl.InclusiveDurationNano / 10000.0 AS decimal(18,1)) AS InclMs,
       COALESCE(mn.Name, LEFT(qs.Statement, 200)) AS What
FROM dbo.TraceLines tl
LEFT JOIN dbo.MethodNames mn ON mn.MethodHash = tl.MethodHash
LEFT JOIN dbo.QueryStatements qs ON qs.QueryStatementHash = tl.QueryStatementHash AND tl.CallTypeId = 64
WHERE tl.UserSessionProcessThreadId = @thread AND tl.ParentSequence = @callSequence
ORDER BY tl.Sequence;
```

Slowest SQL statements of a trace, with execution counts:

```sql
SELECT TOP 20 tl.QueryStatementHash, COUNT_BIG(*) AS Calls,
       CAST(SUM(tl.InclusiveDurationNano) / 10000.0 AS decimal(18,1)) AS TotalMs,
       MIN(LEFT(qs.Statement, 200)) AS Statement
FROM dbo.TraceLines tl
JOIN dbo.UserSessionProcessThreads p ON p.UserSessionProcessThreadId = tl.UserSessionProcessThreadId AND p.TraceId = @trace
JOIN dbo.QueryStatements qs ON qs.QueryStatementHash = tl.QueryStatementHash
WHERE tl.CallTypeId = 64
GROUP BY tl.QueryStatementHash
ORDER BY SUM(tl.InclusiveDurationNano) DESC;
```

All bind values of one SQL call (raw, by position):

```sql
SELECT b.ParameterIndex, b.BindValue FROM dbo.QueryBindParameters b WHERE b.TraceLineId = @traceLineId ORDER BY b.ParameterIndex;
```

Kernel event messages of a thread (skip the very frequent reflection events):

```sql
SELECT tl.Sequence, tl.TraceLineId, tl.EventName, m.MessageText
FROM dbo.TraceLines tl JOIN dbo.Messages m ON m.MessageHash = tl.MessageHash
WHERE tl.UserSessionProcessThreadId = @thread AND tl.EventName <> 'Execution time use of reflection.'
ORDER BY tl.Sequence;
```
