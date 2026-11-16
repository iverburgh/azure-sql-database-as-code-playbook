/*
Post-deployment script of the schema dacpac. Runs after every schema deployment, on every environment.
Keep it idempotent: it runs again on every release.
*/
INSERT INTO [dbo].[DeploymentHistory] ([Type], [Build])
VALUES (N'Schema', N'$(BuildNumber)');
