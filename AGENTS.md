# Florida — guidance for agents

Single-user personal calendar + auto-scheduled tasks (Motion replacement). Speed of the apps is the first requirement: the UI must never wait on the network.

## Layout

- `packages/scheduler/` — `@florida/scheduler`. Pure TypeScript, zero dependencies, no I/O. Must stay portable (no Node-only APIs) so it can later run on-device in JavaScriptCore. Every behavior change needs a test in `test/`.
- `server/` — `@florida/server`. Hono + Drizzle (postgres.js in production, PGlite in tests), Google Calendar sync, jobs. Deployed to Fly from `server/Dockerfile`; `fly.toml` is at the repo root.
- `apple/` — XcodeGen spec (`project.yml`), Swift package `FloridaKit`, and the `iOS/`, `Widgets/`, `macOS/` target sources. Cannot be built on Linux; generate and build on a Mac or a macOS CI runner.

## Commands

```sh
pnpm install
pnpm build        # scheduler first (server imports its dist)
pnpm test
pnpm typecheck
pnpm --filter @florida/server db:generate   # after editing server/src/db/schema.ts
```

## Conventions

- TypeScript: ESM, relative imports end in `.js`, named exports, 2-space indent, single quotes, no semicolons, trailing commas. Strict settings from `tsconfig.base.json` (`exactOptionalPropertyTypes`, `noUncheckedIndexedAccess`) apply everywhere.
- Dates cross the wire as ISO 8601 strings; the database stores `timestamptz`. Wall-clock schedule windows are "HH:MM" in the schedule's IANA time zone.
- Derived data is recomputed, not stored, except `placements` (server-side scheduler output, replaced wholesale on each run) which other consumers need.
- Every mutable table has `updated_at` and a `deleted_at` tombstone; sync is `updated_at > since`.
- Do not add dependencies to `packages/scheduler`. Add server dependencies with `pnpm add` inside `server/`.
- Swift: 4-space indent, SwiftUI, Swift 6 language mode. Keep platform-specific code behind `#if os(...)` inside `FloridaKit` or in the per-target folders.
