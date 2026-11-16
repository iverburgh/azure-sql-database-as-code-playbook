/*
Reference data for every environment. Each included script is a MERGE on fixed keys, so the
deployment is idempotent and the table always ends up exactly as declared here.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

:r ./Seed-OrderStatus.sql
GO
:r ./Seed-ProductCategory.sql
GO
