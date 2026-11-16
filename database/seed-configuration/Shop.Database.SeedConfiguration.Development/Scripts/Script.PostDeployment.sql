/*
Configuration rows for Development. Idempotent: every included script is a MERGE on fixed keys.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

:r ./Seed-PaymentProvider.sql
GO
