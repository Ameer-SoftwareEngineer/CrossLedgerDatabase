-- AML rolling-limit pre-check (specification 4.1), meant to be called before
-- usp_PostTransfer authorises a transfer - it only reports, it never blocks or mutates
-- anything itself, so the caller decides what to do with the answer.
--
-- Scoped per (owner, currency): a rolling limit stated as "$10,000/day" is naturally a
-- single-currency figure, and converting a multi-currency user history into one comparable
-- number would need an FX rate lookup this procedure has no business making. The rolling
-- window is evaluated only against customer wallets - FX settlement accounts are internal,
-- not a customer's own spend.
--
-- CrossLedgerWeb does not yet persist configured limits anywhere (no per-user or per-tier
-- limits table exists), so @RollingLimit is supplied by the caller, the same way
-- Limits:StepUpAbove is read from configuration rather than a database row today.
--
-- "Indexed seek" (specification 4.1) needs an index on Wallets(OwnerId) - Wallets is owned
-- by CrossLedgerWeb's EF Core migrations, not this project, so that index belongs in an EF
-- migration there, not here.
CREATE PROCEDURE dbo.usp_CheckTransferLimits
    @OwnerId          UNIQUEIDENTIFIER,
    @CurrencyCode     NVARCHAR(3),
    @ProposedAmount   DECIMAL(19, 4),
    @RollingLimit     DECIMAL(19, 4)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @WindowStart DATETIMEOFFSET(7) = DATEADD(HOUR, -24, SYSUTCDATETIME());

    DECLARE @RollingTotal DECIMAL(19, 4) = ISNULL((
        SELECT SUM(le.Amount)
        FROM dbo.LedgerEntries AS le
        INNER JOIN dbo.Wallets AS w ON w.Id = le.WalletId
        WHERE w.OwnerId = @OwnerId
          AND w.Kind = 'Customer'
          AND le.CurrencyCode = @CurrencyCode
          AND le.Direction = 'Debit'
          AND le.PostedAt >= @WindowStart
    ), 0);

    SELECT
        @RollingTotal AS RollingTotal,
        @RollingTotal + @ProposedAmount AS ProjectedTotal,
        @RollingLimit AS RollingLimit,
        CAST(CASE WHEN @RollingTotal + @ProposedAmount > @RollingLimit THEN 1 ELSE 0 END AS BIT) AS ExceedsLimit;
END
