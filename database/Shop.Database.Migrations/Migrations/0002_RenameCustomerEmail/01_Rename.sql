-- The schema renames [Sales].[Customer].[Email] to [EmailAddress]. Without this migration the
-- dacpac would drop [Email] and add an empty [EmailAddress]; the publish profile blocks that as
-- possible data loss. sp_rename keeps the data. Guarded, so it is safe on any database state.
-- Only rename a column when no deployed code reads the old name; see docs/breaking-changes.md.
IF COL_LENGTH(N'Sales.Customer', N'Email') IS NOT NULL
    AND COL_LENGTH(N'Sales.Customer', N'EmailAddress') IS NULL
BEGIN
    EXECUTE sp_rename N'Sales.Customer.Email', N'EmailAddress', N'COLUMN';
END
