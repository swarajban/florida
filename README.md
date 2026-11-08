# Florida

A personal replacement for [Motion](https://www.usemotion.com/): work and personal Google calendars plus auto-scheduled tasks, with a keyboard-first macOS app and an iOS app with widgets. Built for one user; speed first.

The full design, decisions, and milestones live in the design document in the project thread. Short version:

- `packages/scheduler/` — pure, deterministic TypeScript scheduler. Places open tasks into free time around calendar events by ASAP → due day → hard/soft → priority, honoring schedules, start dates, minimum chunks, pinned tasks, hard-deadline overflow, and a horizon. No I/O, no dependencies.
- `server/` — Hono + Drizzle API on one always-on Fly machine with Neon Postgres. Mirrors Google Calendar via push notifications, owns tasks/categories/schedules, runs the scheduler, serves a sync API for the apps and an MCP endpoint (`/mcp`) for agents.
- `apple/` — SwiftUI apps for macOS and iOS plus a WidgetKit extension, generated with XcodeGen from `apple/project.yml`, sharing the `FloridaCore` (models, quick-add parser, keyboard engine, grid layout math) and `FloridaKit` (GRDB SQLite store, sync client) Swift packages.

## Develop

```sh
pnpm install
pnpm build          # builds packages/scheduler then server
pnpm test           # vitest in every package
pnpm typecheck
pnpm dev            # server with tsx watch; needs server/.env (see server/.env.example)
```

Apple targets: see `apple/README.md` (`xcodegen generate` on a Mac).

## Deploy

See `server/README.md` for Neon, Google OAuth client, Fly secrets, and `fly deploy`.
