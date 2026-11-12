# Florida — guidance for agents

Single-user personal calendar + auto-scheduled tasks (Motion replacement). Speed of the apps is the first requirement: the UI must never wait on the network.

## Layout

- `packages/scheduler/` — `@florida/scheduler`. Pure TypeScript, zero dependencies, no I/O. Must stay portable (no Node-only APIs) so it can later run on-device in JavaScriptCore. Every behavior change needs a test in `test/`.
- `server/` — `@florida/server`. Hono + Drizzle (postgres.js in production, PGlite in tests), Google Calendar sync, jobs. Deployed to Fly from `server/Dockerfile`; `fly.toml` is at the repo root.
- `apple/` — XcodeGen spec (`project.yml`), two local Swift packages, and the `iOS/`, `Widgets/`, `macOS/` target sources.
  - `apple/FloridaCore/` — dependency-free models (wire-compatible with the server JSON), quick-add parser, keyboard engine, calendar layout math. Pure logic, no I/O.
  - `apple/FloridaKit/` — GRDB/SQLite store, sync client, token store; re-exports FloridaCore. Depends on GRDB 7.
  - Both packages build and test on Linux (`swift build --build-tests && swift test` inside each; Swift 6.4 via swiftly). App targets need Xcode: on a connected Mac, run `bash apple/scripts/check.sh build` before pushing and targeted UI tests while editing. PR CI compiles both apps, widgets and test bundles on every Apple-changing push, but does not run UI tests. Once the head is otherwise ready, request the complete UI gate with `gh workflow run ios.yml --ref <PR-branch> -f ui_only=true`; require its checks to pass on the current head before merge. See `apple/README.md` for full/local/single-test commands. PR CI is the backstop, not the compile loop; report when no Mac is available.
  - On main, full Mac/iPhone UI suites still run, but **the TestFlight UI gate is off for now by Swaraj's choice**. Archive/sign/upload jobs do not depend on UI results; UI failures remain failed checks and are summarized after one failed-test retry. The single switch is `APPLE_UI_GATE` in `.github/workflows/apple-release-policy.yml`; set it to `'true'` to gate both uploads again. Never cancel an upload.

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
- Tasks are grouped by `categories` (name, color, and the schedule whose hours apply), not Motion-style projects. The Swift type is `TaskCategory`: a bare `Category` is ambiguous on Apple platforms because the Objective-C runtime exports `typealias Category = OpaquePointer`, and `Label` collides with SwiftUI's view (same reason `Task` is `TaskItem`). Linux builds do not catch Darwin-only name clashes like this; local Xcode builds and the PR Xcode gate do.
- Dates cross the wire as ISO 8601 strings; the database stores `timestamptz`. Wall-clock schedule windows are "HH:MM" in the schedule's IANA time zone.
- Derived data is recomputed, not stored, except `placements` and `unscheduled` (server-side scheduler output, both replaced wholesale on each run) which other consumers need.
- Every mutable table has `updated_at` and a `deleted_at` tombstone; sync is `updated_at > since`.
- Do not add dependencies to `packages/scheduler`. Add server dependencies with `pnpm add` inside `server/`.
- Swift: 4-space indent, SwiftUI, Swift 6 language mode, swift-testing (`import Testing`) for new tests. Nothing in `FloridaCore` or `FloridaKit` may import SwiftUI/AppKit/UIKit; Darwin-only APIs go behind `#if canImport(...)`. Platform UI lives in the per-target folders.
- Swift models in `FloridaCore/Sources/FloridaCore/Models/Models.swift` mirror `server/src/db/schema.ts` and the `server/src/app.ts` bodies field for field; change both sides together.
