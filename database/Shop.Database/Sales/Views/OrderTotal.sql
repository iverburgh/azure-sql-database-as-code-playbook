CREATE VIEW [Sales].[OrderTotal]
AS
SELECT
    o.[OrderId],
    o.[CurrencyCode],
    SUM(l.[Quantity] * l.[UnitPrice]) AS [Total]
FROM [Sales].[Order] AS o
INNER JOIN [Sales].[OrderLine] AS l ON l.[OrderId] = o.[OrderId]
GROUP BY o.[OrderId], o.[CurrencyCode];
