MERGE INTO [Config].[PaymentProvider] WITH (HOLDLOCK) AS target
USING (VALUES
    (1, N'Card payments', N'https://sandbox.payments.example.com', CAST(1 AS BIT)),
    (2, N'Invoice',       N'https://my-invoicing-dev.example.com', CAST(1 AS BIT))
) AS source ([PaymentProviderId], [Name], [BaseUrl], [IsEnabled])
ON target.[PaymentProviderId] = source.[PaymentProviderId]
WHEN MATCHED AND (target.[Name] <> source.[Name] OR target.[BaseUrl] <> source.[BaseUrl] OR target.[IsEnabled] <> source.[IsEnabled]) THEN
    UPDATE SET [Name] = source.[Name], [BaseUrl] = source.[BaseUrl], [IsEnabled] = source.[IsEnabled]
WHEN NOT MATCHED BY TARGET THEN
    INSERT ([PaymentProviderId], [Name], [BaseUrl], [IsEnabled])
    VALUES (source.[PaymentProviderId], source.[Name], source.[BaseUrl], source.[IsEnabled])
WHEN NOT MATCHED BY SOURCE THEN
    DELETE;
