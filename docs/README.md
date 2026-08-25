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

## Plans

[`plans/`](plans/) holds per-feature design documents — one per substantial
feature, written before implementation and kept as the record of what was
decided and why. New feature plans go here as `<FEATURE>_PLAN.md`.

| Plan | Status |
|---|---|
| [CATEGORIZATION_PLAN.md](plans/CATEGORIZATION_PLAN.md) | ✅ Shipped — category tree, rules, on-device AI suggestions. |
| [DATA_PORTABILITY_PLAN.md](plans/DATA_PORTABILITY_PLAN.md) | ✅ Shipped — `.ttmbackup` export/restore with undo. |

## Elsewhere in the repo

- [`TTMCore/README.md`](../TTMCore/README.md) — engine package overview.
- [`app/README.md`](../app/README.md) — SwiftUI app package.
- [`contract/README.md`](../contract/README.md) — the Milestone 2 cloud API contract.
