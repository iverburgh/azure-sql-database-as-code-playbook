-- Release 1 added [Sales].[Order].[CurrencyCode] as a NULL column and the application started to
-- write it. This migration fills the old rows, so the schema dacpac of this release can make the
-- column NOT NULL without data loss. Migrations run before the schema is deployed.
-- sp_executesql: the column may not exist when the batch is compiled.
IF COL_LENGTH(N'Sales.Order', N'CurrencyCode') IS NOT NULL
BEGIN
    EXECUTE sp_executesql N'UPDATE [Sales].[Order] SET [CurrencyCode] = ''EUR'' WHERE [CurrencyCode] IS NULL;';
END
