-- Balance derivation (specification 4.1). Mirrors Wallet.Balance in CrossLedgerWeb.Domain
-- exactly: sum every LedgerEntries row's signed contribution for the wallet - credits
-- positive, debits negative - rather than transferring the whole entry history to the
-- caller just to add it up in C#.
--
-- Error contract: 50002 WALLET_NOT_FOUND (same code usp_PostTransfer uses).
CREATE PROCEDURE dbo.usp_GetWalletBalance
    @WalletId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Currency NVARCHAR(3) = (SELECT Currency FROM dbo.Wallets WHERE Id = @WalletId);

    IF @Currency IS NULL
        THROW 50002, 'WALLET_NOT_FOUND', 1;

    SELECT
        @WalletId AS WalletId,
        @Currency AS Currency,
        ISNULL(SUM(CASE Direction WHEN 'Credit' THEN Amount WHEN 'Debit' THEN -Amount END), 0) AS Balance
    FROM dbo.LedgerEntries
    WHERE WalletId = @WalletId;
END
