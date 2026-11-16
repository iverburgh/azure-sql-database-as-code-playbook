-- Categories are reference data owned by the code. No WHEN NOT MATCHED BY SOURCE: an old category
-- may still be referenced by products, so removing one is a migration, not a seed change.
MERGE INTO [Catalog].[ProductCategory] WITH (HOLDLOCK) AS target
USING (VALUES
    (1, N'books',       N'Books'),
    (2, N'electronics', N'Electronics'),
    (3, N'garden',      N'Garden')
) AS source ([ProductCategoryId], [Code], [Name])
ON target.[ProductCategoryId] = source.[ProductCategoryId]
WHEN MATCHED AND (target.[Code] <> source.[Code] OR target.[Name] <> source.[Name]) THEN
    UPDATE SET [Code] = source.[Code], [Name] = source.[Name]
WHEN NOT MATCHED BY TARGET THEN
    INSERT ([ProductCategoryId], [Code], [Name]) VALUES (source.[ProductCategoryId], source.[Code], source.[Name]);
