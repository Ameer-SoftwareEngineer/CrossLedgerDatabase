# CrossLedgerDatabase

The stored-procedure layer for [CrossLedgerWeb](https://github.com/Ameer-SoftwareEngineer/CrossLedgerWeb), kept as its own SDK-style SQL Server Database Project rather than living inside the web app's repo.

## Why a separate project

CrossLedgerWeb uses two data-access approaches side by side (see the specification's section 4): EF Core owns single-entity work (creating a wallet, saving a quote), and stored procedures own set-based or multi-statement atomic work (posting a transfer, reconciling the ledger, paged history). This project is the second half of that split, built as a proper "file type that gets published to the database" instead of ad-hoc scripts: `dotnet build` compiles every `.sql` file here into one `.dacpac`, and that `.dacpac` is the single artifact that gets published (locally or in CI) to keep the database's procedures in sync with source control.

**CrossLedgerWeb's own tables are not modeled here.** Its EF Core migrations remain the source of truth for `Wallets`, `LedgerEntries`, `Quotes`, `IdempotencyRecords`, etc. - every procedure in `dbo/StoredProcedures/` runs against those by name without redefining them, which is why the project suppresses SQL71501/71502 ("unresolved reference") in `CrossLedgerDatabase.sqlproj`. The one exception is `dbo/Tables/FxRateSnapshots.sql`, which genuinely is owned here - see `usp_GetFxRateOHLC` below for why.

## Procedures (specification 4.1)

| Procedure | Responsibility | Status |
|---|---|---|
| `usp_PostTransfer` | Atomic money movement - validates balance, locks the wallets, inserts the four ledger entries in one transaction | Done |
| `usp_GetWalletBalance` | Sums ledger entries for a wallet, returns a scalar | Done |
| `usp_GetTransactionHistory` | Server-side paging with `OFFSET`/`FETCH`, plus a total count for the pager | Done |
| `usp_ReconcileLedger` | Nightly integrity check - asserts the ledger sums to zero per currency | Done |
| `usp_GetAccountStatement` | Opening balance plus a running balance via `SUM() OVER (ORDER BY PostedAt)` | Done |
| `usp_CheckTransferLimits` | Rolling 24-hour transfer total per owner and currency, ahead of AML limit enforcement | Done |
| `usp_GetFxRateOHLC` | Daily open/high/low/close aggregation over `dbo.FxRateSnapshots` | Done (source table not yet fed - see below) |

`usp_PostTransfer` does **not** manage idempotency - that's already handled generically for every command by CrossLedgerWeb's `IdempotencyBehavior` pipeline behaviour (specification 2.3), so it would be redundant (and a second, differently-shaped mechanism) to duplicate it here keyed by `TransferId`.

Concurrency is enforced with `UPDLOCK, HOLDLOCK` reads against `LedgerEntries` per wallet (there's no `WalletBalances` row to lock - balances are derived, specification 2.1), with all four wallets touched by a transfer locked in a fixed ascending-id order to rule out deadlocks between two transfers sharing wallets in opposite roles. Verified live: two concurrent calls against the same wallet - one that can afford its debit, one that can't once the first has posted - genuinely serialize (the second visibly blocks until the first commits) rather than racing to read a stale balance.

`usp_CheckTransferLimits` takes its limit as a parameter rather than reading one from a table - CrossLedgerWeb doesn't persist configured limits anywhere yet (`Limits:StepUpAbove` is read from configuration the same way). `usp_GetFxRateOHLC` reads from `dbo.FxRateSnapshots`, a table owned by this project rather than deferred to CrossLedgerWeb, because nothing in the system currently captures FX rates over time to begin with - `IExchangeRateProvider` only fetches a rate live and caches it for an hour (specification 2.5). The aggregation SQL is tested against seeded rows; the scheduled capture job that would actually keep the table fed (specification 3.7's Azure Functions rate refresh) doesn't exist yet.

## Build

```bash
dotnet build
```

Produces `bin/Debug/CrossLedgerDatabase.dacpac`.

## Publish

Requires the SqlPackage CLI (`dotnet tool install -g microsoft.sqlpackage`) or the SQL Database Projects extension for VS Code / Azure Data Studio.

```bash
sqlpackage /Action:Publish /SourceFile:bin/Debug/CrossLedgerDatabase.dacpac /TargetServerName:"(localdb)\mssqllocaldb" /TargetDatabaseName:CrossLedgerDatabase
```

Publishing only ever adds/alters procedures here - it never touches tables, since none are modeled in this project. Run `CrossLedgerWeb`'s own EF Core migrations first against the same database to create the schema these procedures depend on.
