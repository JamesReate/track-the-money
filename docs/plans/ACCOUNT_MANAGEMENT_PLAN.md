# Account management — delete, manual accounts, credit cards, interest rates

- **Status:** Shipped (2026-11-25; §7 2026-11-26)
- **Decided in:** [ADR-0024](../adr/0024-manual-accounts-and-account-deletion.md),
  [ADR-0025](../adr/0025-account-status-excluded-and-paused.md)

## 1. Ask

> I should have a way to delete or rename accounts. Or also add manually
> managed accounts where I just want to put the current value of the account
> and when it was updated.

Rename already exists (ADR-less, migration v3 `nickname`: swipe right / context
menu → *Rename*). This plan adds **delete** and **manual accounts**.

## 2. What exists

- `accounts.connection_id` is `NOT NULL REFERENCES connections(id) ON DELETE
  CASCADE`. Transactions, balance snapshots and property-debt links all cascade
  from the account row.
- `accounts.archived` exists in the v1 schema and is honoured by every
  net-worth query and the app's account list, but nothing ever sets it.
- Net worth over time is built from `balance_snapshots` (step functions).
- The sample-data connection already uses a sentinel `keychain_ref` (`demo`)
  that sync, import re-keying and secret cleanup skip.

## 3. Decisions

### D1 — Manual accounts are ordinary account rows under a hidden local connection

Each store gets (lazily) one connection row `id = "manual"`, `keychain_ref =
"manual"`, named "Manually tracked". Manual accounts hang off it with
`sfin_account_id = "manual-<uuid>"`. No schema change.

- Sync, import re-keying and Keychain cleanup skip it exactly like the sample
  sentinel (`Store.localKeychainRefs`). `connections()` hides it — it is not a
  SimpleFIN connection and has nothing to reconnect.
- Everything downstream (net worth, debt chart, property-debt links, class
  menu) works unchanged because a manual account *is* an account.
- Rejected: making `connection_id` nullable. SQLite needs a full table rebuild
  for that, with four tables and the FTS triggers depending on `accounts` — a
  risky migration for no user-visible gain.

### D2 — A value update is a balance snapshot

"Current value + when it was updated" is a `balance_snapshots` row
(`balance_date` = the as-of day). The account's `balance_cents`/`balance_date`
are recomputed from the latest snapshot, so back-filling an older value never
overwrites today's. Entering a value for a day that already has one replaces
it (`UNIQUE(account_id, balance_date)`).

- The app sends the start of the chosen *local* day; TTMCore stays time-zone
  free (ADR-0010).
- Debts are entered as the positive amount owed (ADR-0012's magnitudes).
- History is listed per account; an entry can be deleted, but not the last one
  (delete the account instead).

### D3 — Delete depends on where the account comes from

| Source | Delete does | Why |
|---|---|---|
| Manual, sample | Removes the row; history, splits and property links cascade. | Nothing will bring it back. |
| SimpleFIN | Removes its transactions, balance history and property links, and keeps the row as a hidden **tombstone** (`archived = 1`) that sync skips. | Deleting the row outright would make the next sync re-import it with full history. |

- Deleted bank accounts are listed at the bottom of Accounts with **Sync
  again** (un-archive). History resumes from the next sync's window (the last
  sync minus 7 days), not the whole backfill — said in the UI.
- To stop sharing an account entirely, the user removes it in SimpleFIN Bridge;
  the delete dialog says so.
- Transfer pairs: the surviving leg of a pair whose other leg is deleted is
  un-paired (`is_transfer = 0`, group cleared, and its auto-assigned Transfer
  category cleared), so it re-enters categorization instead of pointing nowhere.
- An emptied sample connection is removed with its last account, so Settings
  doesn't show "Sample data · 0 accounts".

### D4 — Rename for manual accounts sets the name itself

A manual account has no bank name to fall back to, so rename writes `name`
and clears `nickname`; "Reset to bank name" isn't offered.

## 4. Surface

`CoreFacade`:

```swift
func addManualAccount(name: String, accountClass: AccountClass, balance: Money, asOf: UnixTime) async throws -> String
func setManualBalance(accountId: String, balance: Money, asOf: UnixTime) async throws
func balanceHistory(accountId: String) async throws -> [BalanceEntry]
func deleteBalanceEntry(accountId: String, asOf: UnixTime) async throws
func deleteAccount(accountId: String) async throws
func restoreAccount(accountId: String) async throws
```

`AccountSummary` gains `source: AccountSource` (`synced | manual | sample`) and
`balanceDate`.

App (Accounts tab): **+** → *Add manual account* (name, type, value, as-of
date). Manual rows show "Updated <date>"; tapping one opens *Update value* with
the history. Swipe left / context menu → *Delete* with a source-specific
confirmation. A "Deleted bank accounts" section offers *Sync again*.

## 5. Follow-up ask: interest rates and a credit-card class

> I want to have a way to put the current interest rate for debt (when it is
> classified as a type of debt). I also want to be able to classify something
> as a credit card in the class option.

### D5 — `creditCard` is a class that rolls up as unsecured debt

A new `AccountClass.creditCard` (raw value `creditCard`), a liability. Net
worth and the debt-over-time chart count it with unsecured debt, so every
total — and ADR-0012 — is unchanged; the class only says *what kind* of
unsecured debt it is. The first-sight guesser now maps card names (visa,
mastercard, amex, "credit card", "card ending") to it and checks secured-debt
patterns before the generic "loan" (previously "Honda Auto Loan" guessed
unsecured). Existing accounts keep their class; the user re-picks.

### D6 — APR is user-entered into the existing `apr_bps` column

`setAccountAPR(accountId:aprBps:)` writes `accounts.apr_bps` (basis points,
already in the v1 schema, never used until now). Only debt classes take one,
0–100% (anything higher is a typo); nil clears it. Sync never reports rates
and leaves the column alone. Changing a debt to a non-debt class keeps the
stored rate but hides it.

Surface: debt rows on Accounts show "22.99% APR"; swipe / context menu →
*Interest rate…*; adding a manual debt takes an optional rate. Debt & Interest
gains an **Interest rates** section — debts highest rate first (the
avalanche order), unset ones last with *Set rate*, and a balance-weighted
average.

## 6. Implementation notes

- `NSDecimalNumber(decimal:).intValue` returns garbage for a fractional
  Decimal with a long mantissa — the first cut of the weighted average showed
  "0%". Integer math (`Σ cents × bps / Σ cents`) is exact and fits Int64.
- A `.buttonStyle(.plain)` row in a `List` only takes taps on its content, not
  the spacer between; the rate rows need `.contentShape(Rectangle())`.

## 7. Follow-up ask: excluded and paused accounts

> When I click sync, will it bring back any deleted accounts? Maybe we need
> better control over that, or like disabled accounts.

Sync never brings a deleted account back (D3). But delete was the only way to
stop an account counting, and it discards history. Decided in ADR-0025.

### D7 — A status, separate from the class

`accounts.status` (migration v5): **active**, **excluded** (syncs, left out of
net worth, the series, spending, interest and property equity, and its
transactions hidden from every list, search, count and transfer match),
**paused** (not synced, counts at its last balance; synced accounts only). The
old `excluded` *class* migrates to the status, so excluding a credit card keeps
it a credit card.

### D8 — Catch-up windows

The fetch window is per connection, so an account that was paused, or deleted
and restored, would otherwise miss everything before the connection's last
sync. `accounts.resync_from` widens the next fetch: last balance date − 7 days
on resume, now − 120 days on restore. Never past the backfill; cleared after a
successful sync.

### D9 — Hold new accounts (opt-in)

Settings → SimpleFIN connection → *Hold new accounts for review*. When on,
accounts appearing on an already-synced connection arrive excluded, and the
sync message says how many. Off by default; a first sync is never held.

Surface: Accounts groups *Paused* and *Excluded from totals* below the active
list. Swipe left / context menu → *Exclude from totals* / *Include in totals*,
*Pause syncing* / *Resume syncing*. Debt & Interest ignores excluded debts.

## 8. Out of scope

Deleting a whole SimpleFIN connection; manual transactions; multi-currency
manual accounts (USD, like everything else today); merging a manual account
into a synced one.
