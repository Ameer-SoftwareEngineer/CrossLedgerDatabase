-- Atomic money movement for a cross-currency transfer (specification 2.1, 4.1).
-- Posts the same four balanced ledger entries TransferPoster.Post (CrossLedgerWeb.Domain)
-- posts in-process: debit source, credit source-currency FX settlement, debit
-- target-currency FX settlement, credit target. One round trip instead of four+.
--
-- Deliberately differs from the specification's own illustrative usp_PostTransfer in three
-- ways, because it is written against the schema CrossLedgerWeb's EF Core migrations
-- actually create, not the simplified pseudocode:
--
--   1. There is no dbo.WalletBalances row to lock - a wallet's balance is DERIVED by
--      summing dbo.LedgerEntries (specification 2.1: "never stored as a mutable column").
--      So instead of UPDLOCK on a balance row, each wallet's balance is read with
--      UPDLOCK, HOLDLOCK against LedgerEntries. HOLDLOCK escalates that ranged read to
--      serializable isolation for that WalletId, so a second concurrent transfer touching
--      the same wallet cannot insert its own entry - and so compute its own balance -
--      until this transaction commits or rolls back. That is what actually prevents two
--      concurrent transfers from both passing the balance check against a wallet that can
--      only afford one of them.
--   2. A cross-currency transfer touches two FX settlement wallets, not one - the spec's
--      single @FxSettlementId is a simplification. Both are resolved by the caller
--      (mirroring IFxSettlementWalletResolver) and passed in explicitly.
--   3. Idempotency is not this procedure's concern. CrossLedgerWeb already guarantees
--      exactly-once execution per Idempotency-Key at the MediatR pipeline level
--      (IdempotencyBehavior, specification 2.3), generically for every command - not just
--      transfers - by replaying the stored response for a repeated key. Duplicating that
--      here, keyed by TransferId, would be a second, differently-shaped idempotency
--      mechanism doing the same job.
--
-- Error contract (specification 4.4: deterministic errors, not parsed message strings):
--   50001 INSUFFICIENT_FUNDS   - source wallet cannot cover the debit
--   50002 WALLET_NOT_FOUND     - one of the four wallet ids does not exist
--   50003 CURRENCY_MISMATCH    - a supplied currency code does not match its wallet's
CREATE PROCEDURE dbo.usp_PostTransfer
    @TransferId                  UNIQUEIDENTIFIER,
    @SourceWalletId              UNIQUEIDENTIFIER,
    @FxSettlementSourceWalletId  UNIQUEIDENTIFIER,
    @FxSettlementTargetWalletId  UNIQUEIDENTIFIER,
    @TargetWalletId              UNIQUEIDENTIFIER,
    @SourceAmount                DECIMAL(19, 4),
    @SourceCurrencyCode          NVARCHAR(3),
    @TargetAmount                DECIMAL(19, 4),
    @TargetCurrencyCode          NVARCHAR(3),
    @PostedAt                    DATETIMEOFFSET(7) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @PostedAt IS NULL
        SET @PostedAt = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- The four wallet ids, deduplicated and sorted ascending, so every caller acquires
        -- per-wallet locks in the same fixed order regardless of which wallet plays which
        -- role (source, target, either settlement account). Two transfers that touch an
        -- overlapping pair of wallets in opposite logical roles - e.g. A: X->Y and
        -- concurrently B: Y->X - would deadlock under lock-as-you-go; sorting first makes
        -- that structurally impossible, both always lock in the same ascending order.
        DECLARE @OrderedWalletIds TABLE (Seq INT IDENTITY(1, 1) PRIMARY KEY, WalletId UNIQUEIDENTIFIER NOT NULL);
        INSERT INTO @OrderedWalletIds (WalletId)
        SELECT DISTINCT v.WalletId
        FROM (VALUES (@SourceWalletId), (@FxSettlementSourceWalletId), (@FxSettlementTargetWalletId), (@TargetWalletId)) AS v(WalletId)
        ORDER BY v.WalletId;

        DECLARE @Wallets TABLE
        (
            WalletId  UNIQUEIDENTIFIER PRIMARY KEY,
            Kind      NVARCHAR(20)     NOT NULL,
            Currency  NVARCHAR(3)      NOT NULL,
            Balance   DECIMAL(19, 4)   NOT NULL
        );

        DECLARE @Seq INT = 1, @WalletCount INT = (SELECT COUNT(*) FROM @OrderedWalletIds);
        DECLARE @CurrentWalletId UNIQUEIDENTIFIER, @CurrentKind NVARCHAR(20), @CurrentCurrency NVARCHAR(3);

        WHILE @Seq <= @WalletCount
        BEGIN
            SELECT @CurrentWalletId = WalletId FROM @OrderedWalletIds WHERE Seq = @Seq;

            SELECT @CurrentKind = Kind, @CurrentCurrency = Currency
            FROM dbo.Wallets
            WHERE Id = @CurrentWalletId;

            IF @CurrentKind IS NULL
            BEGIN
                ROLLBACK TRANSACTION;
                THROW 50002, 'WALLET_NOT_FOUND', 1;
            END

            INSERT INTO @Wallets (WalletId, Kind, Currency, Balance)
            SELECT
                @CurrentWalletId,
                @CurrentKind,
                @CurrentCurrency,
                ISNULL((
                    SELECT SUM(CASE le.Direction WHEN 'Credit' THEN le.Amount WHEN 'Debit' THEN -le.Amount END)
                    FROM dbo.LedgerEntries AS le WITH (UPDLOCK, HOLDLOCK)
                    WHERE le.WalletId = @CurrentWalletId
                ), 0);

            SET @Seq += 1;
        END

        IF EXISTS (SELECT 1 FROM @Wallets WHERE WalletId IN (@SourceWalletId, @FxSettlementSourceWalletId) AND Currency <> @SourceCurrencyCode)
           OR EXISTS (SELECT 1 FROM @Wallets WHERE WalletId IN (@FxSettlementTargetWalletId, @TargetWalletId) AND Currency <> @TargetCurrencyCode)
        BEGIN
            ROLLBACK TRANSACTION;
            THROW 50003, 'CURRENCY_MISMATCH', 1;
        END

        -- Non-negative balance is only enforced for customer-owned wallets - an FX
        -- settlement (SystemClearing) wallet legitimately runs negative between the two
        -- legs of a transfer (Wallet.Post in CrossLedgerWeb.Domain applies the same rule).
        IF EXISTS (
            SELECT 1 FROM @Wallets
            WHERE WalletId = @SourceWalletId AND Kind = 'Customer' AND Balance < @SourceAmount
        )
        BEGIN
            ROLLBACK TRANSACTION;
            THROW 50001, 'INSUFFICIENT_FUNDS', 1;
        END

        INSERT INTO dbo.LedgerEntries (Id, TransferId, WalletId, Direction, PostedAt, Amount, CurrencyCode)
        VALUES
            (NEWID(), @TransferId, @SourceWalletId,             'Debit',  @PostedAt, @SourceAmount, @SourceCurrencyCode),
            (NEWID(), @TransferId, @FxSettlementSourceWalletId, 'Credit', @PostedAt, @SourceAmount, @SourceCurrencyCode),
            (NEWID(), @TransferId, @FxSettlementTargetWalletId, 'Debit',  @PostedAt, @TargetAmount, @TargetCurrencyCode),
            (NEWID(), @TransferId, @TargetWalletId,             'Credit', @PostedAt, @TargetAmount, @TargetCurrencyCode);

        COMMIT TRANSACTION;

        SELECT @TransferId AS TransferId, 'COMPLETED' AS Status, @PostedAt AS PostedAt;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
