-- Monthly statement (specification 4.1): a running balance via SUM() OVER (ORDER BY
-- PostedAt) - the kind of thing that "cannot be expressed cleanly through LINQ"
-- (specification section 4). The opening balance carries forward everything posted
-- strictly before the statement window, so a mid-history statement doesn't start from
-- zero.
--
-- ORDER BY PostedAt, Id (not PostedAt alone): usp_PostTransfer posts all four legs of a
-- transfer with the exact same @PostedAt value, so Id is the tie-breaker that keeps the
-- running balance - and the row order a caller sees - deterministic across re-runs.
CREATE PROCEDURE dbo.usp_GetAccountStatement
    @WalletId  UNIQUEIDENTIFIER,
    @FromDate  DATETIMEOFFSET(7),
    @ToDate    DATETIMEOFFSET(7)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OpeningBalance DECIMAL(19, 4) = ISNULL((
        SELECT SUM(CASE Direction WHEN 'Credit' THEN Amount WHEN 'Debit' THEN -Amount END)
        FROM dbo.LedgerEntries
        WHERE WalletId = @WalletId AND PostedAt < @FromDate
    ), 0);

    SELECT @OpeningBalance AS OpeningBalance;

    SELECT
        Id, TransferId, Direction, Amount, CurrencyCode, PostedAt,
        @OpeningBalance + SUM(CASE Direction WHEN 'Credit' THEN Amount WHEN 'Debit' THEN -Amount END)
            OVER (ORDER BY PostedAt, Id ROWS UNBOUNDED PRECEDING) AS RunningBalance
    FROM dbo.LedgerEntries
    WHERE WalletId = @WalletId
      AND PostedAt >= @FromDate
      AND PostedAt <= @ToDate
    ORDER BY PostedAt, Id;
END
