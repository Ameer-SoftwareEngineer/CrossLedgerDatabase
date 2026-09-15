-- Daily open/high/low/close aggregation over dbo.FxRateSnapshots for the rate chart
-- (specification 4.1) - window functions doing exactly what the specification says LINQ
-- cannot express cleanly. ROW_NUMBER ordered ascending/descending per day identifies each
-- day's first and last observation (open/close); MIN/MAX give the day's low/high directly.
--
-- See FxRateSnapshots.sql for why this table is currently unpopulated in production - the
-- aggregation below is correct and tested against seeded rows regardless.
CREATE PROCEDURE dbo.usp_GetFxRateOHLC
    @FromCurrency  NVARCHAR(3),
    @ToCurrency    NVARCHAR(3),
    @FromDate      DATE,
    @ToDate        DATE
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH DailyRates AS (
        SELECT
            CAST(CapturedAt AS DATE) AS RateDate,
            MidMarketRate,
            ROW_NUMBER() OVER (PARTITION BY CAST(CapturedAt AS DATE) ORDER BY CapturedAt ASC)  AS OpenRank,
            ROW_NUMBER() OVER (PARTITION BY CAST(CapturedAt AS DATE) ORDER BY CapturedAt DESC) AS CloseRank
        FROM dbo.FxRateSnapshots
        WHERE FromCurrency = @FromCurrency
          AND ToCurrency = @ToCurrency
          AND CapturedAt >= CAST(@FromDate AS DATETIMEOFFSET)
          AND CapturedAt < CAST(DATEADD(DAY, 1, @ToDate) AS DATETIMEOFFSET)
    )
    SELECT
        RateDate,
        MAX(CASE WHEN OpenRank = 1 THEN MidMarketRate END)  AS [Open],
        MAX(MidMarketRate)                                    AS High,
        MIN(MidMarketRate)                                    AS Low,
        MAX(CASE WHEN CloseRank = 1 THEN MidMarketRate END) AS [Close]
    FROM DailyRates
    GROUP BY RateDate
    ORDER BY RateDate;
END
