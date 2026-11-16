CREATE TABLE [Catalog].[ProductCategory]
(
    [ProductCategoryId] INT           NOT NULL,
    [Code]              NVARCHAR (30) NOT NULL,
    [Name]              NVARCHAR (100) NOT NULL,
    CONSTRAINT [PK_ProductCategory] PRIMARY KEY CLUSTERED ([ProductCategoryId]),
    CONSTRAINT [UQ_ProductCategory_Code] UNIQUE ([Code])
);
