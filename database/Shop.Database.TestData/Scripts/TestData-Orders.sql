-- One order per test customer, only when the customer has none yet.
INSERT INTO [Sales].[Order] ([CustomerId], [OrderStatusId], [OrderedAt], [CurrencyCode], [ModifiedBy])
SELECT c.[CustomerId], 1, SYSDATETIMEOFFSET(), 'EUR', N'test-data'
FROM [Sales].[Customer] AS c
WHERE c.[EmailAddress] IN (N'alice@example.com', N'bob@example.com')
    AND NOT EXISTS (SELECT 1 FROM [Sales].[Order] AS o WHERE o.[CustomerId] = c.[CustomerId]);

INSERT INTO [Sales].[OrderLine] ([OrderId], [ProductId], [Quantity], [UnitPrice])
SELECT o.[OrderId], p.[ProductId], 1, p.[UnitPrice]
FROM [Sales].[Order] AS o
INNER JOIN [Sales].[Customer] AS c ON c.[CustomerId] = o.[CustomerId]
CROSS JOIN [Catalog].[Product] AS p
WHERE c.[EmailAddress] IN (N'alice@example.com', N'bob@example.com')
    AND p.[Sku] = N'BOOK-0001'
    AND NOT EXISTS (SELECT 1 FROM [Sales].[OrderLine] AS l WHERE l.[OrderId] = o.[OrderId]);
