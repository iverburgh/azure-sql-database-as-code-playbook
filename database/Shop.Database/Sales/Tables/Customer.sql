CREATE TABLE [Sales].[Customer]
(
    [CustomerId]   INT                IDENTITY (1, 1) NOT NULL,
    [EmailAddress] NVARCHAR (320)     NOT NULL,
    [DisplayName]  NVARCHAR (200)     NOT NULL,
    [CreatedAt]    DATETIMEOFFSET (7) NOT NULL CONSTRAINT [DF_Customer_CreatedAt] DEFAULT (SYSDATETIMEOFFSET()),
    [ModifiedAt]   DATETIMEOFFSET (7) NULL,
    [ModifiedBy]   NVARCHAR (128)     NULL,
    CONSTRAINT [PK_Customer] PRIMARY KEY CLUSTERED ([CustomerId])
);
GO

CREATE NONCLUSTERED INDEX [IX_Customer_EmailAddress]
    ON [Sales].[Customer] ([EmailAddress]);
