CREATE TABLE [Sales].[Order]
(
    [OrderId]       INT                IDENTITY (1, 1) NOT NULL,
    [CustomerId]    INT                NOT NULL,
    [OrderStatusId] TINYINT            NOT NULL,
    [OrderedAt]     DATETIMEOFFSET (7) NOT NULL,
    [CurrencyCode]  CHAR (3)           NOT NULL,
    [Note]          NVARCHAR (500)     NULL,
    [CreatedAt]     DATETIMEOFFSET (7) NOT NULL CONSTRAINT [DF_Order_CreatedAt] DEFAULT (SYSDATETIMEOFFSET()),
    [ModifiedAt]    DATETIMEOFFSET (7) NULL,
    [ModifiedBy]    NVARCHAR (128)     NULL,
    CONSTRAINT [PK_Order] PRIMARY KEY CLUSTERED ([OrderId]),
    CONSTRAINT [FK_Order_Customer] FOREIGN KEY ([CustomerId]) REFERENCES [Sales].[Customer] ([CustomerId]),
    CONSTRAINT [FK_Order_OrderStatus] FOREIGN KEY ([OrderStatusId]) REFERENCES [Sales].[OrderStatus] ([OrderStatusId])
);
GO

CREATE NONCLUSTERED INDEX [IX_Order_CustomerId]
    ON [Sales].[Order] ([CustomerId]);
