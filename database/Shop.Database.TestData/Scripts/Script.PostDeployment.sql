/*
Test data. Idempotent: rows are matched on natural keys (e-mail address, SKU), so a second
deployment adds nothing. Tests may change these rows; the next deployment does not reset them.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

:r ./TestData-Customers.sql
GO
:r ./TestData-Products.sql
GO
:r ./TestData-Orders.sql
GO
