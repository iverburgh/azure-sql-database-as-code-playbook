CREATE TABLE [Sales].[OrderStatus]
(
    [OrderStatusId] TINYINT       NOT NULL,
    [Code]          NVARCHAR (20) NOT NULL,
    [Name]          NVARCHAR (50) NOT NULL,
    CONSTRAINT [PK_OrderStatus] PRIMARY KEY CLUSTERED ([OrderStatusId]),
    CONSTRAINT [UQ_OrderStatus_Code] UNIQUE ([Code])
);
