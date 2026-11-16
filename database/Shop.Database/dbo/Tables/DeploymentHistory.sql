-- Part of the schema, so DropObjectsNotInSource never drops it, and also included with :r by the
-- migrations dacpac, which creates it on a new database. No GO and no separate statements: the
-- include sits inside an IF block.
CREATE TABLE [dbo].[DeploymentHistory]
(
    [DeploymentHistoryId] INT                IDENTITY (1, 1) NOT NULL,
    [Type]                NVARCHAR (20)      NOT NULL,
    [Build]               NVARCHAR (50)      NOT NULL,
    [MigrationId]         INT                NULL,
    [Name]                NVARCHAR (200)     NULL,
    [DeployedAt]          DATETIMEOFFSET (7) NOT NULL CONSTRAINT [DF_DeploymentHistory_DeployedAt] DEFAULT (SYSDATETIMEOFFSET()),
    CONSTRAINT [PK_DeploymentHistory] PRIMARY KEY CLUSTERED ([DeploymentHistoryId])
);
