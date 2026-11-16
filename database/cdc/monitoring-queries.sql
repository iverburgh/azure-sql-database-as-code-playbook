/*
Read-only monitoring queries for change data capture (CDC) and the transaction log.
Run them in the database itself. None of them changes anything.
See docs/cdc-and-schema-changes.md.
*/

-- 1. How full is the transaction log, and what keeps it from being reused?
--    REPLICATION as the wait reason means: the CDC capture has not read the log yet.
SELECT
    d.[name]                                AS [Database],
    d.log_reuse_wait_desc                   AS [LogReuseWait],
    CAST(u.used_log_space_in_percent AS DECIMAL(5, 2)) AS [UsedLogPercent],
    CAST(u.total_log_size_in_bytes / 1048576.0 AS DECIMAL(12, 1)) AS [LogSizeMB]
FROM sys.databases AS d
CROSS JOIN sys.dm_db_log_space_usage AS u
WHERE d.[name] = DB_NAME();

-- 2. Is the capture keeping up? Latency is the delay, in seconds, between a commit and its capture.
--    A growing latency, or no recent session, is the early warning.
SELECT TOP (20)
    s.session_id,
    s.start_time,
    s.end_time,
    s.duration,
    s.tran_count,
    s.command_count,
    s.latency,
    s.error_count
FROM sys.dm_cdc_log_scan_sessions AS s
ORDER BY s.start_time DESC;

-- 3. Capture errors. Error 2628 (string or binary data would be truncated) means a captured column
--    is wider in the table than in its capture instance: the capture stops and the log grows.
SELECT TOP (20)
    e.session_id,
    e.entry_time,
    e.error_number,
    e.error_severity,
    e.error_message
FROM sys.dm_cdc_errors AS e
ORDER BY e.entry_time DESC;

-- 4. Captured columns whose definition in the table no longer matches the capture instance.
--    The change table (cdc.<capture instance>_CT) keeps the definition from when the instance was
--    created, so compare the two. Every row here needs a new capture instance, planned with the
--    owner of the change feed. Shown as type(max_length in bytes, precision, scale).
--    Only works once CDC is enabled (the cdc schema exists).
SELECT
    ct.capture_instance                      AS [CaptureInstance],
    OBJECT_SCHEMA_NAME(ct.source_object_id)  AS [Schema],
    OBJECT_NAME(ct.source_object_id)         AS [Table],
    cc.column_name                           AS [Column],
    CONCAT(TYPE_NAME(captured.user_type_id), N'(', captured.max_length, N',', captured.[precision], N',', captured.scale, N')') AS [Captured],
    CASE WHEN current_column.column_id IS NULL THEN N'dropped'
         ELSE CONCAT(TYPE_NAME(current_column.user_type_id), N'(', current_column.max_length, N',', current_column.[precision], N',', current_column.scale, N')')
    END                                      AS [Current]
FROM cdc.change_tables AS ct
INNER JOIN cdc.captured_columns AS cc ON cc.[object_id] = ct.[object_id]
INNER JOIN sys.columns AS captured ON captured.[object_id] = ct.[object_id] AND captured.[name] = cc.column_name
LEFT JOIN sys.columns AS current_column ON current_column.[object_id] = ct.source_object_id AND current_column.[name] = cc.column_name
WHERE current_column.column_id IS NULL
   OR current_column.user_type_id <> captured.user_type_id
   OR current_column.max_length <> captured.max_length
   OR current_column.[precision] <> captured.[precision]
   OR current_column.scale <> captured.scale
ORDER BY [Schema], [Table], [Column];
