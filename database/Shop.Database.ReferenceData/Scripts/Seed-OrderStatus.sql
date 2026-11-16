-- The application maps these ids to an enum, so they never change. Rows that are not listed are
-- deleted; a status that is still referenced by an order makes the deployment fail, which is the
-- point: remove the code and the data first.
MERGE INTO [Sales].[OrderStatus] WITH (HOLDLOCK) AS target
USING (VALUES
    (CAST(1 AS TINYINT), N'Placed',    N'Placed'),
    (CAST(2 AS TINYINT), N'Paid',      N'Paid'),
    (CAST(3 AS TINYINT), N'Shipped',   N'Shipped'),
    (CAST(4 AS TINYINT), N'Cancelled', N'Cancelled')
) AS source ([OrderStatusId], [Code], [Name])
ON target.[OrderStatusId] = source.[OrderStatusId]
WHEN MATCHED AND (target.[Code] <> source.[Code] OR target.[Name] <> source.[Name]) THEN
    UPDATE SET [Code] = source.[Code], [Name] = source.[Name]
WHEN NOT MATCHED BY TARGET THEN
    INSERT ([OrderStatusId], [Code], [Name]) VALUES (source.[OrderStatusId], source.[Code], source.[Name])
WHEN NOT MATCHED BY SOURCE THEN
    DELETE;
