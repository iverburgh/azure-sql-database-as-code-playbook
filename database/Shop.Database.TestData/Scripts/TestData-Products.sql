INSERT INTO [Catalog].[Product] ([Sku], [Name], [ProductCategoryId], [UnitPrice], [ModifiedBy])
SELECT source.[Sku], source.[Name], source.[ProductCategoryId], source.[UnitPrice], N'test-data'
FROM (VALUES
    (N'BOOK-0001', N'A Book About Databases', 1, CAST(24.95 AS DECIMAL(19, 4))),
    (N'ELEC-0001', N'USB Cable',              2, CAST(7.50 AS DECIMAL(19, 4))),
    (N'GARD-0001', N'Watering Can',           3, CAST(12.00 AS DECIMAL(19, 4)))
) AS source ([Sku], [Name], [ProductCategoryId], [UnitPrice])
WHERE NOT EXISTS (SELECT 1 FROM [Catalog].[Product] AS p WHERE p.[Sku] = source.[Sku]);
