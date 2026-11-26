# ADR-0023 — Profiles: one store per data set, switched in place; secrets stay per connection

- **Status:** Accepted
- **Date:** 2026-11-25
- **Source:** [plans/PROFILES_PLAN.md](../plans/PROFILES_PLAN.md) §4, §5
- **Related:** [ADR-0007](0007-corefacade-boundary.md), [ADR-0013](0013-access-url-keychain-only.md),
  [ADR-0019](0019-restore-replaces-everything.md), [ADR-0020](0020-backups-exclude-secrets.md)

## Context

Moving between data sets — above all a real bank and a test bank — meant
export → restore → export → restore, with one generation of undo and the risk of
forgetting to export first. The ask was "load a file and keep going", including
the SimpleFIN connection.

Two shapes were considered: **profiles** (several stores on the device) and a
**portable file that carries the connection** (Access URL sealed under a
passphrase). The second would supersede ADR-0020 and amend ADR-0013, and make a
backup as sensitive as a bank password. It only matters for a *different*
device; on the same device the connection already survives, because the
Keychain item is keyed per connection (`conn-<UUID>`) and restore never touches
the Keychain.

## Decision

- **Profiles, no portable connection.** Each profile is its own SQLite store at
  `<root>/profiles/<id>/ttm.db`; a JSON registry (`<root>/profiles.json`) names
  them and records the active one. A pre-profiles `<root>/ttm.db` is adopted as
  "My data" on first launch. ADR-0013 and ADR-0020 stand unchanged.
- **Switching rebinds `LocalCore` in place** (the same swappable-internals
  mechanism as restore, ADR-0019), behind the unchanged `CoreFacade`. Restore and
  undo act on the active profile.
- **A backup can be opened as a new profile**, non-destructively, as well as
  replacing the current one.
- **Each profile owns its Keychain items.** Import gives every connection a
  fresh ref (copying the secret when the old ref resolves). Deleting a profile
  removes only secrets no remaining store — including any undo copy — points at;
  if any store can't be read, nothing is deleted.
- **Connection state is first-class.** `connections()` reports, per connection,
  `connected / missingCredential / needsAuth / error / sample`; `reconnect`
  attaches a new Access URL to the *existing* connection so accounts continue
  instead of duplicating. Sample-data connections are skipped by sync.
- **Profile kind is `real | test`**, display only: a test profile shows a banner
  on every screen.

## Consequences

- Test vs. real is one tap, and a test file with no connection simply loads.
- A new device still needs a fresh setup token per connection — now surfaced as
  "Not linked on this device · Reconnect…" rather than a generic notice.
- Profile operations live in `ProfileManager` (pure Foundation file work);
  `LocalCore(dbPath:)` remains for tests and has no profiles
  (`ProfileError.unavailable`).
- Switching mid-sync is prevented in the app layer, not the engine; an in-flight
  sync holding the old store would fail. Revisit if background refresh lands.
- Revisit the portable connection only if cross-device handoff without
  re-linking becomes a real need — and do it as an ADR superseding 0020.
