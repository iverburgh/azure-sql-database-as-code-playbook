CREATE TABLE [Config].[PaymentProvider]
(
    [PaymentProviderId] INT            NOT NULL,
    [Name]              NVARCHAR (100) NOT NULL,
    [BaseUrl]           NVARCHAR (400) NOT NULL,
    [IsEnabled]         BIT            NOT NULL,
    CONSTRAINT [PK_PaymentProvider] PRIMARY KEY CLUSTERED ([PaymentProviderId])
);
