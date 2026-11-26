# Agent access: letting Claude (or any MCP client) query your data locally

- **Status:** Planned (2026-11-26). Not started.
- **Decided in:** nothing yet. Write ADR-0027 when implementation starts (§9).

## 1. Ask

> Now I want to think of ways of interacting with the data via an agent, e.g.
> Claude. Since this runs locally (not the cloud server option), what would be
> best? CLI? Use case would be from a Mac, maybe in the future Omarchy Linux too.
> Would a local MCP be viable? I want the agent to have flexibility querying the
> db, like being able to run flexible SQL queries, which means it would need to
> know the schema.

## 2. The concept

Add one Swift command-line tool, **`ttm`**, built on TTMCore. It has two faces:

- **Terminal commands** (`ttm sql`, `ttm schema`, `ttm networth`, …). They are
  useful on their own and callable from Claude Code's shell.
- **`ttm mcp`**: the same features served over the Model Context Protocol on
  standard input and output. Claude Desktop, Claude Code or any MCP client
  starts it as a local process. Nothing listens on a port and no server runs
  in the cloud.

The agent gets three kinds of access:

1. **Free-form read-only SQL** over a set of curated *agent views*. The views
   bake in the app's rules (cents, debt signs, excluded accounts, category
   groups), so ordinary queries give the same answers as the app.
2. **A self-describing schema**: `describe_schema` returns the view definitions,
   the raw tables and a written guide to the data's rules.
3. **A few computed tools** for figures the app already calculates and that
   plain SQL gets wrong (net worth over time, debt and promo outlook). They call
   TTMCore's own code, so the agent's numbers match the screens.

Writes are out of scope for the first version (§8).

### Example questions this should handle

- "What did I spend on dining each month this year, and which month was the outlier?"
- "List every subscription-looking charge that recurs monthly, with the latest amount."
- "How has my net worth moved since January, and which accounts drove it?"
- "Can my cash clear the Visa promo before it ends if I keep spending like last quarter?"
- "Which merchants are still uncategorized, ranked by total spent?"

## 3. Options considered

| Option | Flexible SQL | Matches the app's numbers | Linux later | Verdict |
|---|---|---|---|---|
| Claude Code skill + `sqlite3 -readonly` | Full | Only if the instructions are followed | Yes | A good quick trial; nothing enforces safety; can't open a WAL file read-only when the app closed cleanly |
| **`ttm` tool + `ttm mcp` on TTMCore** | Full, through the views | Yes | Yes (Swift + GRDB) | **Chosen** |
| Separate Python or TypeScript MCP server | Full | No: it re-implements the app's math, and the copy drifts | Yes | Rejected |
| App Intents (Siri / Shortcuts) | None | Yes | No | Complementary later; not for analysis |
| MCP server running inside the app (localhost HTTP) | Full | Yes | No | Rejected: only works while the app is open; needs a port and authentication |
| A `VACUUM INTO` snapshot per session | Full | Yes | Yes | Kept as a fallback mode (D3); data is stale and large stores are slow |

## 4. What the agent has to know beyond the schema

The raw tables (`TTMCore/Sources/TTMCore/Persistence/Database.swift`, v1–v6)
are easy to misread. The agent views encode these rules, and the written guide
spells them out:

- **Money:** `*_cents` columns are integer cents. In `transactions.amount_cents`,
  negative means money out (SimpleFIN's convention).
- **Debt balances keep the bank's sign.** Some banks report debt as negative.
  Debt classes (`securedDebt`, `creditCard`, `unsecuredDebt`) read as
  `abs()` (ADR-0012).
- **Account status** (ADR-0025):
  - `excluded` accounts count nowhere, and their transactions are hidden
    everywhere (`Store.visibleTxn`).
  - `paused` accounts still count.
  - `archived = 1` marks an account the user deleted: a leftover marker, not data.
- **Transfers** (`is_transfer = 1`) are not spending. The app's spending total
  is outflows only, excluding transfers and excluded accounts, filtered on
  `posted_at`. Pending rows have no `posted_at` and so fall outside it.
- **Time:** UTC seconds since 1970. Local-day boundaries matter. Promo end days
  are stored as the start of the last local day (ADR-0026).
- **Categories have two levels** (ADR-0015). Transactions sit on leaves, and a
  leaf's group is its `parent_id`. The system categories are `income`,
  `transfer`, `interest` and `uncategorized`.
- **Display names:** an account's display name is `COALESCE(nickname, name)`.
  `connections.keychain_ref` values `demo` and `manual` mark sample and manual
  holders.
- **Net worth is a step function:** each account holds its last known value
  between snapshots, and properties and their linked debts also feed in. This
  is what the `net_worth*` tools exist for; don't expect the agent to rebuild it
  in SQL.

## 5. Decisions (proposed; confirm at implementation)

### D1: One package and one binary; TTMCore stays pure

Create a new SPM package, `cli/` (product `ttm`), that depends on `../TTMCore`,
[swift-argument-parser](https://github.com/apple/swift-argument-parser) and an
MCP implementation (D7).

- TTMCore gains only pure, OS-free pieces: a read-only open, a profile registry
  reader, the agent-view SQL, a guarded query runner, and a read facade.
- Standard input and output, argument parsing, MCP framing and JSON output live
  in `cli/`.
- Nothing in TTMCore imports the MCP library (ADR-0006).

### D2: The agent never migrates, seeds or adopts

`Database(path:)` runs migrations, `LocalCore` runs
`DefaultData.ensureCategories`, and `ProfileManager.init` can adopt a legacy
store and rewrite `profiles.json`. All three write. Agent access therefore uses
new entry points that never write:

- `ProfileRegistry.read(root:)` parses `profiles.json` and touches nothing.
- `Database(readingAt:)` opens the file without migrating.
- A schema check reads `grdb_migrations` and requires it to **equal**
  `Database.knownMigrations`:
  - older: refuse, with "open Track The Money once to upgrade this profile";
  - newer: refuse, with "update ttm".

  The agent views target the exact schema, so a near match isn't good enough.
  When `ttm` ships inside the app bundle (§7 phase 4), the two never disagree.

### D3: Read-only in layers

Layer 1 is the open itself. Open the file normally (read and write), then
immediately set `PRAGMA query_only = ON`, which blocks every write.

- *Why not a plain read-only open:* a store that closed cleanly has no `-shm`
  file, and a read-only WAL open then fails. This is the gotcha already
  recorded for `BackupManager.inspect`.
- *The one side effect:* when the last connection closes, SQLite checkpoints the
  WAL, the same as the app does. If a read-only open turns out to be workable
  (try it first, keep this as the fallback), prefer it.
- *Snapshot mode:* `--snapshot` uses a private `VACUUM INTO` copy instead. It
  gives total isolation and stale data.

Layer 2 is a SQLite authorizer (a callback that approves or refuses each step
of a statement):

- Allow `SELECT`, `READ`, `FUNCTION` and `RECURSIVE`, plus `PRAGMA` reads of
  `table_info`, `table_xinfo`, `index_list`, `foreign_key_list` and
  `table_list`.
- Deny everything else, including `ATTACH`, `DETACH`, every `CREATE`, `DROP`,
  `INSERT`, `UPDATE` and `DELETE`, transactions, and other pragmas.
- Install it *after* the temp views are created (D4).

Layer 3 is per-statement checks:

- Exactly one statement: reject a non-empty tail after preparing.
- The prepared statement must report itself read-only (`sqlite3_stmt_readonly`,
  which GRDB exposes as `Statement.isReadonly`).

Layer 4 is limits:

- A default row cap of 500, configurable up to 5,000, with `truncated: true`
  in the result when it's hit.
- Cells longer than 2 KB are truncated.
- A wall-clock timeout of 5 s by default, enforced with `interrupt()`, so a
  runaway recursive query can't hang the client.

### D4: Agent views are temporary views on the connection, not migrations

On connect, `ttm` runs `CREATE TEMP VIEW …` before installing the authorizer.
Temporary views:

- exist only on that connection, so they never touch the file, the schema,
  backups or the app;
- carry a version number in the guide, and change with the tool rather than
  through a migration.

They are the **supported contract** for agents. Raw tables stay readable but
the guide labels them "internal, may change". This keeps ADR-0007's boundary
honest: a future Rust core would need to reproduce the views, not the tables.

Draft views, to be checked against the facade by the parity tests in §6:

```sql
-- Accounts the user hasn't deleted. Debt balances as positive magnitudes.
CREATE TEMP VIEW v_accounts AS
SELECT a.id,
       COALESCE(a.nickname, a.name)                     AS name,
       a.name                                           AS bank_name,
       a.class, a.status,
       (a.status <> 'excluded')                         AS counts,
       CASE WHEN a.class IN ('securedDebt','creditCard','unsecuredDebt')
            THEN abs(a.balance_cents) ELSE a.balance_cents END AS balance_cents,
       date(a.balance_date, 'unixepoch', 'localtime')   AS balance_on,
       a.apr_bps / 100.0                                AS apr_percent,
       a.promo_apr_bps / 100.0                          AS promo_apr_percent,
       date(a.promo_ends_on, 'unixepoch', 'localtime')  AS promo_last_day,
       c.name                                           AS connection,
       (c.keychain_ref = 'manual')                      AS is_manual,
       (c.keychain_ref = 'demo')                        AS is_sample,
       a.currency
FROM accounts a JOIN connections c ON c.id = a.connection_id
WHERE a.archived = 0;

-- Transactions the app would show: excluded and deleted accounts filtered out.
CREATE TEMP VIEW v_transactions AS
SELECT t.id, t.account_id,
       COALESCE(a.nickname, a.name)                         AS account,
       a.class                                              AS account_class,
       date(t.posted_at, 'unixepoch', 'localtime')          AS posted_on,
       date(t.transacted_at, 'unixepoch', 'localtime')      AS transacted_on,
       t.posted_at, t.transacted_at,
       t.amount_cents,                                      -- negative = money out
       t.description, t.payee, t.memo,
       t.pending, t.is_transfer,
       t.category_id,
       COALESCE(cat.name, 'Uncategorized')                  AS category,
       COALESCE(grp.name, cat.name, 'Uncategorized')        AS category_group,
       cat.kind                                             AS category_kind,
       t.category_source
FROM transactions t
JOIN accounts a          ON a.id = t.account_id
LEFT JOIN categories cat ON cat.id = t.category_id
LEFT JOIN categories grp ON grp.id = cat.parent_id
WHERE a.status <> 'excluded' AND a.archived = 0;

-- Spending as the app defines it.
CREATE TEMP VIEW v_spending AS
SELECT * , -amount_cents AS spent_cents FROM v_transactions
WHERE amount_cents < 0 AND is_transfer = 0 AND posted_at IS NOT NULL;

-- Balance history; debt magnitudes; local dates.
CREATE TEMP VIEW v_balances AS
SELECT s.account_id, COALESCE(a.nickname, a.name) AS account, a.class,
       date(s.balance_date, 'unixepoch', 'localtime') AS on_day,
       CASE WHEN a.class IN ('securedDebt','creditCard','unsecuredDebt')
            THEN abs(s.balance_cents) ELSE s.balance_cents END AS balance_cents
FROM balance_snapshots s JOIN accounts a ON a.id = s.account_id
WHERE a.archived = 0 AND a.status <> 'excluded';

-- The category tree, flattened.
CREATE TEMP VIEW v_categories AS
SELECT c.id, c.name, p.name AS group_name, c.kind,
       EXISTS (SELECT 1 FROM categories k WHERE k.parent_id = c.id) AS is_group
FROM categories c LEFT JOIN categories p ON p.id = c.parent_id;
```

The views use SQLite's `'localtime'`, which follows the process time zone. That
is correct for a tool on the user's machine. TTMCore itself stays free of time
zones (ADR-0010): the SQL is a constant, and the local-time interpretation
happens when `ttm` runs it.

Open item: check whether `accounts.balance_cents` always equals the latest
snapshot for manual accounts, or whether `v_accounts` should read
`balance_snapshots`. The parity test against `accounts()` settles it.

### D5: Hide columns the agent has no use for

The authorizer returns `SQLITE_IGNORE` (the column reads as NULL) for:

- `transactions.extra_json` (the raw bank payload);
- `connections.keychain_ref` and `connections.sfin_org`;
- `connections.last_error`, which can echo bank responses.

The views already expose `is_manual` and `is_sample`. The SimpleFIN Access URL
is never in the database (ADR-0013), so no secret can be read this way.
Excluded accounts' transactions stay out of the views but remain readable in
the raw tables. That is honest, but the guide should say so, and D6's switch is
the real control.

### D6: Agent access is opt-in per profile

- Add a per-profile switch, **"Allow agent access"**, under Settings → Profiles,
  stored in that profile's `settings` table as `agent_access = 1`.
- `ttm` refuses a profile whose switch is off, and names the setting.
- Default: **on for test profiles, off for real profiles.**
- `ttm mcp --profile <name>` pins one profile. Without it, the server uses the
  active profile and `list_profiles` shows only the profiles that allow access.

Whatever the agent reads goes to its model provider as conversation context.
This is the one real change to the local-first promise. The app itself still
sends nothing, and an MCP client running a local model keeps everything on the
machine. ADR-0027 records it.

### D7: MCP over standard input/output; the library is chosen at implementation

- Prefer the official Swift SDK (`modelcontextprotocol/swift-sdk`), provided it
  builds for macOS 14 and on Linux at implementation time.
- Otherwise implement the small subset by hand over JSON-RPC: `initialize`,
  `tools/list`, `tools/call`, `resources/list` and `resources/read`.
- Logs go to standard error only; standard output carries only protocol
  messages.

## 6. Interface

### Command line

```
ttm profiles                                   # profiles that allow agent access, active marked
ttm schema   [--profile P]                     # views, raw tables, the guide (Markdown)
ttm sql "<SELECT …>" [--profile P] [--format table|json|csv] [--max-rows N] [--snapshot]
ttm networth [--from D] [--to D] [--profile P] # summary, or series with dates
ttm spending --from D --to D [--by category|group|month]
ttm debts                                      # balances, effective APR, promo outlook
ttm interest --from D --to D
ttm search "<text>" [--from D] [--to D]        # full-text search over the FTS table, like the app
ttm mcp      [--profile P]                     # MCP server over standard input/output
```

### MCP tools

| Tool | Arguments | Returns |
|---|---|---|
| `list_profiles` | none | The profiles that allow access: id, name, kind, which is active |
| `describe_schema` | `profile?` | The guide, the view definitions, the raw table definitions, the view version |
| `query` | `sql`, `profile?`, `max_rows?` | `columns`, `rows`, `row_count`, `truncated`, `elapsed_ms` |
| `net_worth` | `as_of?`, `from?`, `to?` | A summary (assets, liabilities, liquid, by class) or a series |
| `spending` | `from`, `to`, `by?` | Lines from `LocalCore.spending`, optionally grouped |
| `debts` | none | `accounts()` debts plus `effectiveAprBps`, `promoOutlook()` |
| `interest` | `from`, `to` | `interestSummary` |
| `search_transactions` | `text`, `from?`, `to?`, `limit?` | Full-text search the same way the app searches |

MCP resources: `ttm://guide` and `ttm://schema` hold the same text as
`describe_schema`, so a client can attach them without spending a tool call.

Tool descriptions tell the agent to call `describe_schema` once at the start
and to prefer the `v_*` views.

### Read facade

The computed tools reuse `LocalCore`'s existing read paths: `netWorthSummary`,
`netWorthSeries`, `spending`, `interestSummary`, `promoOutlook`, `accounts` and
`transactions`. These are reads over `Store` today. Two pieces of work follow:

1. Extract a narrow `ReadFacade` protocol covering those methods, plus
   `query(_:limits:)`, `schemaGuide()` and `profiles()`. Both `LocalCore` and a
   new `ReadOnlyCore` (built on D2's open and D3's guards) conform to it.
2. Audit each of those paths for writes; none are expected. A test that hashes
   the database file before and after enforces it (§8).

## 7. Phases

1. **Engine (TTMCore).**
   - `ProfileRegistry.read`, `Database(readingAt:)` and the schema check.
   - `AgentViews.sql`, the guide text and the guarded query runner (authorizer,
     single statement, `isReadonly`, limits, hidden columns).
   - `ReadFacade` and `ReadOnlyCore`.
   - Tests (§8).
2. **`cli/` package: terminal commands.**
   - Output formats and date arguments: local `YYYY-MM-DD`, converted with
     the process time zone.
   - Root folder: `~/Library/Application Support/TrackTheMoney` on macOS;
     `$XDG_DATA_HOME/trackthemoney` (or `~/.local/share/trackthemoney`) on
     Linux; overridable with `--root` / `TTM_ROOT`.
   - Usable from Claude Code through a short skill file as soon as this phase lands.
3. **`ttm mcp`.**
   - The tools and resources from §6.
   - Set up in Claude Code with `claude mcp add ttm -- ttm mcp`, or project
     `.mcp.json`.
   - Set up in Claude Desktop through its MCP config; look at packaging it as
     an MCP bundle (`.mcpb`) for one-click install.
4. **App integration.**
   - `project.yml` embeds `ttm` in the app bundle (`Contents/Helpers/ttm`).
   - Settings gets an "Agent access" section:
     - the per-profile switch (D6);
     - "Install command-line tool…", which links it into `~/.local/bin` or
       `/usr/local/bin`;
     - "Copy Claude Code command" and "Copy Claude Desktop config".
   - The bundle guarantees the tool and the app match the schema (D2).
5. **Later, separate decisions.**
   - **Writes through the facade, never through SQL:** `set_category`,
     `create_rule` (with a dry-run count), `rename_account`. MCP clients
     already ask before each tool call, which fits ADR-0017.
   - **The open app noticing outside writes:** it needs a cross-process change
     signal. `PRAGMA data_version` reveals another connection's commit, so the
     app could check it when it becomes active or on a timer, then call
     `refresh()`.
   - **The Linux app itself** (Omarchy) is its own project. The `ttm` tool
     already runs there against a copied or synced store.

## 8. Testing

Engine tests (XCTest, temporary folders, sample data):

- **Parity:**
  - `v_spending` grouped by category equals `spending(from:to:)`;
  - `v_accounts.balance_cents` equals `accounts()` balances for counting accounts;
  - `v_transactions` row count equals `transactions(TxnQuery())`, ignoring
    paging;
  - excluded accounts are absent from every `v_*` view except `v_accounts`
    (`counts = 0`).
- **Guards reject:**
  - `INSERT`, `UPDATE`, `DELETE`, `DROP`, `CREATE TEMP TABLE` and `ATTACH`;
  - `PRAGMA journal_mode = DELETE`;
  - two statements separated by `;`;
  - `SELECT load_extension(…)`.
- **Guards allow** `WITH RECURSIVE`, window functions, `json_*` and full-text
  `MATCH`.
- **Limits:**
  - the row cap sets `truncated`;
  - a 10⁹-step recursive query is interrupted within the timeout.
- **Hidden columns:** `SELECT extra_json FROM transactions` returns NULLs.
- **Nothing changes on disk:**
  - the database's content hash and `grdb_migrations` are identical after a
    session;
  - `profiles.json` is untouched;
  - no category reseeding happens (count and update times unchanged).
- **Schema check:** a v5 fixture (`Database.migrator(through:)`) is refused
  with the upgrade message; a fixture with an unknown migration is refused with
  the update message.
- **Opt-in:** a profile with `agent_access` unset or `0` is refused.

CLI and MCP tests:

- Expected-output tests over a sample profile in a temporary root.
- A scripted MCP session (`initialize` → `tools/list` → `tools/call query`)
  over pipes.

By hand: Claude Code and Claude Desktop against a **test profile**, never a real
profile during development.

## 9. ADR to write when this starts

**ADR-0027: Local agent access is read-only, opt-in per profile, and goes
through curated views.**
- It records D2–D6.
- It amends the spirit of ADR-0001 by stating plainly that the data reaches
  whichever model the user's client uses.
- It names the `v_*` views, not the tables, as the stable surface next to
  ADR-0007.

## 10. Open questions

- Should excluded accounts be readable at all through the raw tables, or should
  the authorizer also block raw-table reads of their rows? Row-level blocking
  isn't possible in an authorizer, so the answer would be "raw tables off".
- Should a whole session be pinned to one profile, or may the agent switch
  profiles between calls?
- Mac App Store sandboxing would move the store into the app's container and
  constrain an embedded helper. That's moot while the app ships unsandboxed;
  revisit with distribution.
- A Rust core (ADR-0008) would carry `ttm` along naturally: the views and the
  guide are plain SQL and text.
