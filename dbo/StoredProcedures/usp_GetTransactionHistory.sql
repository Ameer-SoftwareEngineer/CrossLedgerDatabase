-- Server-side paging over one wallet's ledger entries (specification 4.1), backing the
-- Transaction History screen (specification section 9: "server-side paged data grid with
-- filtering"). Two result sets - the page itself, then the total row count for the pager -
-- rather than a second round trip, and OFFSET/FETCH rather than pulling every row into the
-- application to page in memory.
--
-- The existing IX_LedgerEntries_WalletId_PostedAt index (CrossLedgerWeb's
-- LedgerEntryConfiguration) already covers the WalletId equality filter plus the PostedAt
-- ordering this relies on.
CREATE PROCEDURE dbo.usp_GetTransactionHistory
    @WalletId    UNIQUEIDENTIFIER,
    @PageNumber  INT = 1,
    @PageSize    INT = 20,
    @FromDate    DATETIMEOFFSET(7) = NULL,
    @ToDate      DATETIMEOFFSET(7) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize < 1 OR @PageSize > 200 SET @PageSize = 20;

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    SELECT
        Id, TransferId, Direction, Amount, CurrencyCode, PostedAt,
        CASE Direction WHEN 'Credit' THEN Amount WHEN 'Debit' THEN -Amount END AS SignedAmount
    FROM dbo.LedgerEntries
    WHERE WalletId = @WalletId
      AND (@FromDate IS NULL OR PostedAt >= @FromDate)
      AND (@ToDate IS NULL OR PostedAt <= @ToDate)
    ORDER BY PostedAt DESC, Id DESC
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(*) AS TotalCount
    FROM dbo.LedgerEntries
    WHERE WalletId = @WalletId
      AND (@FromDate IS NULL OR PostedAt >= @FromDate)
      AND (@ToDate IS NULL OR PostedAt <= @ToDate);
END
