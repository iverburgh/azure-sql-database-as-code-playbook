CREATE TABLE [Sales].[OrderLine]
(
    [OrderLineId] INT             IDENTITY (1, 1) NOT NULL,
    [OrderId]     INT             NOT NULL,
    [ProductId]   INT             NOT NULL,
    [Quantity]    INT             NOT NULL,
    [UnitPrice]   DECIMAL (19, 4) NOT NULL,
    CONSTRAINT [PK_OrderLine] PRIMARY KEY CLUSTERED ([OrderLineId]),
    CONSTRAINT [FK_OrderLine_Order] FOREIGN KEY ([OrderId]) REFERENCES [Sales].[Order] ([OrderId]),
    CONSTRAINT [FK_OrderLine_Product] FOREIGN KEY ([ProductId]) REFERENCES [Catalog].[Product] ([ProductId]),
    CONSTRAINT [CK_OrderLine_Quantity] CHECK ([Quantity] > 0)
);
GO

CREATE NONCLUSTERED INDEX [IX_OrderLine_OrderId]
    ON [Sales].[OrderLine] ([OrderId]);
