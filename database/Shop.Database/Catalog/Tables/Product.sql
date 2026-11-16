CREATE TABLE [Catalog].[Product]
(
    [ProductId]         INT               IDENTITY (1, 1) NOT NULL,
    [Sku]               NVARCHAR (40)     NOT NULL,
    [Name]              NVARCHAR (200)    NOT NULL,
    [ProductCategoryId] INT               NOT NULL,
    [UnitPrice]         DECIMAL (19, 4)   NOT NULL,
    [CreatedAt]         DATETIMEOFFSET (7) NOT NULL CONSTRAINT [DF_Product_CreatedAt] DEFAULT (SYSDATETIMEOFFSET()),
    [ModifiedAt]        DATETIMEOFFSET (7) NULL,
    [ModifiedBy]        NVARCHAR (128)    NULL,
    CONSTRAINT [PK_Product] PRIMARY KEY CLUSTERED ([ProductId]),
    CONSTRAINT [UQ_Product_Sku] UNIQUE ([Sku]),
    CONSTRAINT [FK_Product_ProductCategory] FOREIGN KEY ([ProductCategoryId]) REFERENCES [Catalog].[ProductCategory] ([ProductCategoryId]),
    CONSTRAINT [CK_Product_UnitPrice] CHECK ([UnitPrice] >= 0)
);
