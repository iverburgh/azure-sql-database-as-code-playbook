INSERT INTO [Sales].[Customer] ([EmailAddress], [DisplayName], [ModifiedBy])
SELECT source.[EmailAddress], source.[DisplayName], N'test-data'
FROM (VALUES
    (N'alice@example.com', N'Alice Example'),
    (N'bob@example.com',   N'Bob Example')
) AS source ([EmailAddress], [DisplayName])
WHERE NOT EXISTS (SELECT 1 FROM [Sales].[Customer] AS c WHERE c.[EmailAddress] = source.[EmailAddress]);
