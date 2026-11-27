# Documentation

Everything about how Track The Money is designed, built, and where it stands.
The repo root keeps only [`README.md`](../README.md) (project landing page) and
[`CLAUDE.md`](../CLAUDE.md) (context for Claude Code sessions).

## Reference

| Doc | What it's for |
|---|---|
| [PLAN.md](PLAN.md) | Product plan — features, free/paid line, milestones. |
| [TECH_DESIGN.md](TECH_DESIGN.md) | Architecture: TTMCore/app boundary, SQLite schema, sync + rules + net-worth engines, repo boundary. |
| [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) | Running status and resume pointer — what's done, what's next. Update it when you land work. |
| [BUILD.md](BUILD.md) | Build matrix: XcodeGen, `xcodebuild` invocations, iOS/macOS targets. |

## Decisions

[`adr/`](adr/) holds one Architecture Decision Record per decision — the context,
the choice, and what it costs. Records are immutable: when a decision changes,
add one that supersedes it. Start at [`adr/README.md`](adr/README.md) for the
indexed list; copy [`adr/TEMPLATE.md`](adr/TEMPLATE.md) to add one.

The split between the folders: an **ADR** records *what was decided and why*; a
**plan** records *how a feature will be built*. Plans generate ADRs — the eight
locked decisions in the backup plan became ADR-0018 through ADR-0020.

## Plans

[`plans/`](plans/) holds per-feature design documents — one per substantial
feature, written before implementation and kept as the record of what was
decided and why. New feature plans go here as `<FEATURE>_PLAN.md`.

| Plan | Status |
|---|---|
| [CATEGORIZATION_PLAN.md](plans/CATEGORIZATION_PLAN.md) | ✅ Shipped — category tree, rules, on-device AI suggestions. |
| [DATA_PORTABILITY_PLAN.md](plans/DATA_PORTABILITY_PLAN.md) | ✅ Shipped — `.ttmbackup` export/restore with undo. |
| [PROFILES_PLAN.md](plans/PROFILES_PLAN.md) | ✅ Shipped — switchable profiles, open a backup as a profile, per-profile connection status. |
| [ACCOUNT_MANAGEMENT_PLAN.md](plans/ACCOUNT_MANAGEMENT_PLAN.md) | ✅ Shipped — delete accounts, manually tracked accounts, credit-card class, interest rates on debts, excluded and paused accounts. |
| [PROMO_APR_PLAN.md](plans/PROMO_APR_PLAN.md) | ✅ Shipped (first cut) — credit-card promo rates with an end date; can cash clear them in time. |
| [EXPECTED_EXPENSES_PLAN.md](plans/EXPECTED_EXPENSES_PLAN.md) | ✅ Shipped (first cut) — This Month: big recurring bills expected and knocked off as they arrive. |
| [MONTHLY_BUDGET_DESIGN.html](plans/MONTHLY_BUDGET_DESIGN.html) | 🎨 Design mock — monthly budget: everyday budget, category plans, splurge room, "Can I afford it?". Open in a browser; plan to follow. |
| [MONTHLY_BUDGET_PLAN.md](plans/MONTHLY_BUDGET_PLAN.md) | ✅ Shipped (first cut) — monthly budget: expected income by payer, category plans with carry-over, splurge room, "Can I afford it?" with saved purchases. |
| [AGENT_ACCESS_PLAN.md](plans/AGENT_ACCESS_PLAN.md) | 📝 Planned — `ttm` CLI + local MCP server: read-only SQL over curated views for Claude or any MCP client. |

## Elsewhere in the repo

- [`TTMCore/README.md`](../TTMCore/README.md) — engine package overview.
- [`app/README.md`](../app/README.md) — SwiftUI app package.
- [`contract/README.md`](../contract/README.md) — the Milestone 2 cloud API contract.
