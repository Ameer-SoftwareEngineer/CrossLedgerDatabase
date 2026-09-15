-- Raw periodic FX rate observations, feeding usp_GetFxRateOHLC's daily open/high/low/close
-- aggregation (specification 4.1). Unlike every other table this project's procedures run
-- against, this one has no CrossLedgerWeb EF Core counterpart to defer to - there is
-- currently no scheduled job anywhere in the system that captures rates over time
-- (CrossLedgerWeb's IExchangeRateProvider chain only fetches a rate live, on demand, and
-- caches it in memory for an hour - specification 2.5 - it never persists a history). So
-- this table is genuinely owned here, and is honestly empty in production until that
-- capture job - specification 3.7's "Azure Functions: scheduled FX rate refresh",
-- Phase 1's week-11 cloud-deploy milestone - actually exists. usp_GetFxRateOHLC's SQL is
-- correct and tested against seeded rows; the pipeline that would keep this table fed is
-- the acknowledged gap, not this table's shape.
CREATE TABLE dbo.FxRateSnapshots
(
    Id             UNIQUEIDENTIFIER  NOT NULL CONSTRAINT DF_FxRateSnapshots_Id DEFAULT NEWID(),
    FromCurrency   NVARCHAR(3)       NOT NULL,
    ToCurrency     NVARCHAR(3)       NOT NULL,
    MidMarketRate  DECIMAL(18, 8)    NOT NULL,
    CapturedAt     DATETIMEOFFSET(7) NOT NULL,
    CONSTRAINT PK_FxRateSnapshots PRIMARY KEY (Id)
);
GO

CREATE INDEX IX_FxRateSnapshots_Pair_CapturedAt ON dbo.FxRateSnapshots (FromCurrency, ToCurrency, CapturedAt);
