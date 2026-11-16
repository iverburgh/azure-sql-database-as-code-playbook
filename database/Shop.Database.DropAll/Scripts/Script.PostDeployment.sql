/*
Drops every user object in the database. Guarded: /v:ConfirmDropAll must name this database.
Change data capture is disabled first, because CDC objects block dropping captured tables.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF DB_NAME() <> N'$(ConfirmDropAll)'
BEGIN
    DECLARE @message NVARCHAR(400) = CONCAT(N'Refusing to drop all objects: ConfirmDropAll must be ''', DB_NAME(), N'''.');
    THROW 50000, @message, 1;
END

IF EXISTS (SELECT 1 FROM sys.databases WHERE [name] = DB_NAME() AND is_cdc_enabled = 1)
BEGIN
    PRINT N'Disabling change data capture.';
    EXECUTE sys.sp_cdc_disable_db;
END

DECLARE @sql NVARCHAR(MAX);

SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(N'ALTER TABLE ', QUOTENAME(SCHEMA_NAME(t.[schema_id])), N'.', QUOTENAME(t.[name]), N' DROP CONSTRAINT ', QUOTENAME(fk.[name]), N';')), NCHAR(10))
FROM sys.foreign_keys AS fk
INNER JOIN sys.tables AS t ON t.[object_id] = fk.[parent_object_id]
WHERE t.is_ms_shipped = 0;
IF @sql IS NOT NULL EXECUTE sp_executesql @sql;

SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(N'DROP ',
        CASE o.[type] WHEN 'V' THEN N'VIEW' WHEN 'P' THEN N'PROCEDURE' ELSE N'FUNCTION' END, N' ',
        QUOTENAME(SCHEMA_NAME(o.[schema_id])), N'.', QUOTENAME(o.[name]), N';')), NCHAR(10))
FROM sys.objects AS o
WHERE o.[type] IN ('V', 'P', 'FN', 'IF', 'TF') AND o.is_ms_shipped = 0 AND SCHEMA_NAME(o.[schema_id]) NOT IN (N'sys', N'cdc');
IF @sql IS NOT NULL EXECUTE sp_executesql @sql;

SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(N'DROP TABLE ', QUOTENAME(SCHEMA_NAME(t.[schema_id])), N'.', QUOTENAME(t.[name]), N';')), NCHAR(10))
FROM sys.tables AS t
WHERE t.is_ms_shipped = 0 AND SCHEMA_NAME(t.[schema_id]) NOT IN (N'sys', N'cdc');
IF @sql IS NOT NULL EXECUTE sp_executesql @sql;

SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(N'DROP SEQUENCE ', QUOTENAME(SCHEMA_NAME(s.[schema_id])), N'.', QUOTENAME(s.[name]), N';')), NCHAR(10))
FROM sys.sequences AS s;
IF @sql IS NOT NULL EXECUTE sp_executesql @sql;

SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(N'DROP TYPE ', QUOTENAME(SCHEMA_NAME(ty.[schema_id])), N'.', QUOTENAME(ty.[name]), N';')), NCHAR(10))
FROM sys.types AS ty
WHERE ty.is_user_defined = 1;
IF @sql IS NOT NULL EXECUTE sp_executesql @sql;

-- User schemas only: ids 1-4 are dbo, guest, INFORMATION_SCHEMA and sys; 16384 and up are roles.
SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(N'DROP SCHEMA ', QUOTENAME(s.[name]), N';')), NCHAR(10))
FROM sys.schemas AS s
WHERE s.[schema_id] > 4 AND s.[schema_id] < 16384 AND s.[name] <> N'cdc';
IF @sql IS NOT NULL EXECUTE sp_executesql @sql;

PRINT CONCAT(N'Dropped all user objects in ', DB_NAME(), N'.');
