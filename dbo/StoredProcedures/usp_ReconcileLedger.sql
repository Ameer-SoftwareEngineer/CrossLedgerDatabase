-- Nightly integrity check (specification 2.1, 4.1): the double-entry invariant is that
-- every currency's ledger entries sum to exactly zero, always. Pure set-based aggregation
-- over the entire table - the kind of work that belongs in SQL, not pulled into C# to add
-- up (specification section 4's decision rule).
--
-- Returns the offending currencies (empty if the ledger is healthy) and also throws
-- 50004 LEDGER_IMBALANCE when any exist, so a scheduled caller can both log the detail
-- and treat a non-zero exit as an incident.
CREATE PROCEDURE dbo.usp_ReconcileLedger
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Imbalances TABLE (CurrencyCode NVARCHAR(3) PRIMARY KEY, NetAmount DECIMAL(19, 4));

    INSERT INTO @Imbalances (CurrencyCode, NetAmount)
    SELECT
        CurrencyCode,
        SUM(CASE Direction WHEN 'Credit' THEN Amount WHEN 'Debit' THEN -Amount END) AS NetAmount
    FROM dbo.LedgerEntries
    GROUP BY CurrencyCode
    HAVING SUM(CASE Direction WHEN 'Credit' THEN Amount WHEN 'Debit' THEN -Amount END) <> 0;

    SELECT CurrencyCode, NetAmount FROM @Imbalances;

    IF EXISTS (SELECT 1 FROM @Imbalances)
        THROW 50004, 'LEDGER_IMBALANCE', 1;
END
