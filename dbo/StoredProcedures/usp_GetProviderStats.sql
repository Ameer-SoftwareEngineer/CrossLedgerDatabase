-- Routing engine's two historical scoring signals (specification 5.3): rolling 24h
-- success rate and remaining daily volume headroom, both computed from stored payout
-- outcomes rather than a live provider call. Replaces CrossLedgerWeb's
-- DefaultProviderStatsProvider placeholder, which always reported full marks.
--
-- Rolling success rate is scoped to dbo.Payouts.ProviderCode, which only ever holds the
-- MOST RECENT provider a payout was submitted to (CrossLedgerWeb's Payout.cs documents
-- this) - a payout that failed over from one provider to another is only ever counted
-- against whichever provider ended up with it, never the earlier failure. Good enough to
-- separate a reliable provider from a flaky one over time, not a full per-attempt ledger.
--
-- Daily volume headroom is scoped per (ProviderCode, CurrencyCode), same reasoning as
-- usp_CheckTransferLimits' own per-currency scoping: a limit stated as "$50,000/day"
-- is a single-currency figure, and converting a multi-currency provider history into one
-- comparable number would need an FX rate lookup this procedure has no business making.
--
-- CrossLedgerWeb does not persist a configured per-provider limit anywhere, so
-- @DailyVolumeLimit is supplied by the caller, the same way @RollingLimit is in
-- usp_CheckTransferLimits (Limits:ProviderDailyVolumeLimit in configuration).
--
-- Needs an index on Payouts(ProviderCode, UpdatedAt) - owned by CrossLedgerWeb's EF Core
-- migrations, not this project, same split as usp_CheckTransferLimits' Wallets(OwnerId).
CREATE PROCEDURE dbo.usp_GetProviderStats
    @ProviderCode       NVARCHAR(20),
    @CurrencyCode       NVARCHAR(3),
    @DailyVolumeLimit   DECIMAL(19, 4)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RollingWindowStart DATETIMEOFFSET(7) = DATEADD(HOUR, -24, SYSUTCDATETIME());
    DECLARE @DayStart DATETIMEOFFSET(7) = CAST(CAST(SYSUTCDATETIME() AS DATE) AS DATETIMEOFFSET(7));

    -- Only these four states are reachable once a provider has actually been engaged
    -- (Quoted/Reserved precede routing) and represent a settled outcome, successful or
    -- not - Submitted/Processing are still in flight and neither count yet.
    DECLARE @OutcomeCount INT = (
        SELECT COUNT(*)
        FROM dbo.Payouts
        WHERE ProviderCode = @ProviderCode
          AND State IN ('Settled', 'ProviderFailed', 'PendingManual', 'Reversed')
          AND UpdatedAt >= @RollingWindowStart
    );

    DECLARE @SettledCount INT = (
        SELECT COUNT(*)
        FROM dbo.Payouts
        WHERE ProviderCode = @ProviderCode
          AND State = 'Settled'
          AND UpdatedAt >= @RollingWindowStart
    );

    DECLARE @TodayVolume DECIMAL(19, 4) = ISNULL((
        SELECT SUM(Amount)
        FROM dbo.Payouts
        WHERE ProviderCode = @ProviderCode
          AND CurrencyCode = @CurrencyCode
          AND UpdatedAt >= @DayStart
    ), 0);

    SELECT
        -- No outcome yet today for this provider - same "assume the best until proven
        -- otherwise" default ProviderStats.Unknown uses, rather than penalising a
        -- provider nobody has used recently.
        CASE WHEN @OutcomeCount = 0 THEN CAST(1 AS DECIMAL(19, 4))
             ELSE CAST(@SettledCount AS DECIMAL(19, 4)) / @OutcomeCount
        END AS RollingSuccessRate,
        CASE WHEN @DailyVolumeLimit <= 0 THEN CAST(0 AS DECIMAL(19, 4))
             ELSE CAST(
                CASE WHEN 1 - (@TodayVolume / @DailyVolumeLimit) < 0 THEN 0
                     WHEN 1 - (@TodayVolume / @DailyVolumeLimit) > 1 THEN 1
                     ELSE 1 - (@TodayVolume / @DailyVolumeLimit)
                END AS DECIMAL(19, 4))
        END AS RemainingDailyHeadroomRatio;
END
