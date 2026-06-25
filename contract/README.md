# Sync & AI Contract (source of truth)

This directory is the **public source of truth** for the wire protocol between the on-device app (this repo, free) and the cloud backend (private `track-the-money-cloud`, paid tier).

It can live in the open because **sync payloads are end-to-end encrypted** — the server stores and relays opaque ciphertext, so publishing the protocol shape weakens nothing.

- `openapi.yaml` — REST contract for sync, AI categorization, auth/device registration.
- The private backend vendors a copy of this spec and implements against it.

Free users never hit these endpoints (the app is fully local, rules-only). Only paid, signed-in users sync to the cloud or use AI categorization.
