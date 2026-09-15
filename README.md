# CrossLedgerDatabase

The stored-procedure layer for [CrossLedgerWeb](https://github.com/Ameer-SoftwareEngineer/CrossLedgerWeb), kept as its own SDK-style SQL Server Database Project rather than living inside the web app's repo.

## Why a separate project

CrossLedgerWeb uses two data-access approaches side by side (see the specification's section 4): EF Core owns single-entity work (creating a wallet, saving a quote), and stored procedures own set-based or multi-statement atomic work (posting a transfer, reconciling the ledger, paged history). This project is the second half of that split, built as a proper "file type that gets published to the database" instead of ad-hoc scripts: `dotnet build` compiles every `.sql` file here into one `.dacpac`, and that `.dacpac` is the single artifact that gets published (locally or in CI) to keep the database's procedures in sync with source control.

**Table schema is not modeled here.** `CrossLedgerWeb`'s EF Core migrations remain the source of truth for every table (`Wallets`, `LedgerEntries`, `Quotes`, `IdempotencyRecords`, etc.). Every procedure in `dbo/StoredProcedures/` runs against those tables by name without redefining them, which is why the project suppresses SQL71501 ("unresolved reference") in `CrossLedgerDatabase.sqlproj` - that warning is expected on every procedure here and is not a real error.

## Planned procedures (specification 4.1)

| Procedure | Responsibility |
|---|---|
| `usp_PostTransfer` | Atomic money movement - validates balance, locks the row, inserts the four ledger entries and the idempotency record in one transaction |
| `usp_GetWalletBalance` | Sums ledger entries forward from the latest snapshot, returns a scalar |
| `usp_GetTransactionHistory` | Server-side paging with `OFFSET`/`FETCH` |
| `usp_ReconcileLedger` | Nightly integrity check - asserts the ledger sums to zero per currency |
| `usp_GetAccountStatement` | Running balance via `SUM() OVER (ORDER BY PostedAt)` |
| `usp_CheckTransferLimits` | Rolling 24-hour transfer total via an indexed seek, ahead of AML limit enforcement |
| `usp_GetFxRateOHLC` | Daily open/high/low/close aggregation for the rate chart |

None of these exist yet - this repo currently holds just the project skeleton.

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
