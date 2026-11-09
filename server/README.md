# @florida/server

Hono + Drizzle API for Florida: stores schedules, categories and tasks, mirrors Google Calendar
events, runs `@florida/scheduler` after every change, and serves the result to the apps.

- Production: Node 26 on Fly, Neon Postgres via postgres.js.
- Tests: the same app against PGlite (in-process Postgres), no network.

## Local development

```sh
pnpm install
pnpm build                                   # scheduler first; the server imports its dist
cp server/.env.example server/.env           # fill in the values below
pnpm --filter @florida/server test
pnpm --filter @florida/server typecheck
set -a; source server/.env; set +a
pnpm --filter @florida/server exec tsx src/migrate.ts
pnpm --filter @florida/server seed
pnpm --filter @florida/server dev
```

After editing `src/db/schema.ts`, run `pnpm --filter @florida/server db:generate` and commit the
new file under `server/drizzle/`.

## Setup

### 1. Neon

Create a project at <https://neon.tech>. On the dashboard, copy the **pooled** connection string
(the host contains `-pooler`) and use it as `DATABASE_URL`. The server sets `prepare: false`
because the pooled endpoint runs PgBouncer in transaction mode.

### 2. Google Cloud

1. Create a project at <https://console.cloud.google.com>.
2. **APIs & Services → Library**: enable **Google Calendar API**.
3. **APIs & Services → OAuth consent screen**: fill in the app name and your email. Add the scope
   `https://www.googleapis.com/auth/calendar`.
4. **APIs & Services → Credentials → Create credentials → OAuth client ID**, type **Web
   application**. Add the authorized redirect URI `${PUBLIC_URL}/auth/google/callback`, e.g.
   `https://florida-swaraj.fly.dev/auth/google/callback`. Copy the client ID and secret.

Work account caveat: a Google Workspace organisation often blocks third-party apps that request
calendar access. If the consent screen for your work account refuses, create the Cloud project
*inside the workspace* (signed in as the work account) and set the consent screen's user type to
**Internal**. Connecting a personal Gmail account to an Internal app is not possible, so you may
end up with two OAuth clients; only one can be configured per deployment, so in that case run the
external one and ask the workspace admin to allow-list it.

### 3. Secrets

```sh
openssl rand -hex 32   # API_TOKEN
openssl rand -hex 32   # TOKEN_ENCRYPTION_KEY
```

Optional: an Anthropic API key (`ANTHROPIC_API_KEY`) enables `POST /api/ai/parse-task` and
`POST /api/ai/suggest-category`; the model defaults to `claude-sonnet-5-5` (`ANTHROPIC_MODEL`). Without the key the rest of the server works
unchanged and the AI route answers 503.

### 4. Deploy to Fly

From the repository root (`fly.toml` lives there and points at `server/Dockerfile`):

```sh
fly launch --no-deploy --copy-config --name florida-swaraj --region lax
fly secrets set \
  DATABASE_URL='postgres://...-pooler.../neondb?sslmode=require' \
  API_TOKEN='...' \
  TOKEN_ENCRYPTION_KEY='...' \
  GOOGLE_CLIENT_ID='...' \
  GOOGLE_CLIENT_SECRET='...' \
  PUBLIC_URL='https://florida-swaraj.fly.dev' \
  ANTHROPIC_API_KEY='...'
fly deploy --ha=false
```

`fly deploy` builds the image, runs `node server/dist/migrate.js` as the release command, and
starts one always-on `shared-cpu-1x` machine with a `/health` check. `--ha=false` matters on the
first deploy only: without it Fly launches a second machine, which doubles the bill and runs the
sync and scheduler jobs twice (`fly scale count 1` undoes that).

### 5. Seed and connect calendars

```sh
fly ssh console -C "node server/dist/seed.js"
```

This creates the schedules `work` (Mon–Fri 09:00–12:00, 13:00–17:00 Pacific) and `personal`
(Mon–Fri 18:00–21:00, Sat–Sun 10:00–18:00 Pacific) and the categories `inbox`, `work` (schedule
`work`) and `personal` (schedule `personal`). Re-seeding resets the schedules and the inbox but
never touches `work` or `personal` once they exist, so your edits to them survive.

Then open these in a browser, signing in with the matching Google account each time:

```
https://florida-swaraj.fly.dev/auth/google/start?label=work&key=<API_TOKEN>
https://florida-swaraj.fly.dev/auth/google/start?label=personal&key=<API_TOKEN>
```

Each connection stores the encrypted refresh token, lists the account's calendars (owner/writer
calendars are selected by default), does a full sync of the last 30 days / next 365 days, and
registers a push channel at `${PUBLIC_URL}/webhooks/google`. Channels are renewed every 6 h;
calendars are re-synced every 60 min as a fallback and the scheduler reruns every 15 min.

### 6. Let Google deliver push notifications

Google only posts calendar notifications to a domain you have verified; until then the watch
registration fails (logged as `[google] watch … failed`) and changes arrive with the hourly poll.
One-time setup:

1. In [Search Console](https://search.google.com/search-console), add a **URL prefix** property
   for `https://florida-swaraj.fly.dev/`, choose the **HTML tag** method, and copy the tag's
   `content` value.
2. `fly secrets set GOOGLE_SITE_VERIFICATION=<value>`: the server serves that tag on `/`. Then
   click **Verify** in Search Console.
3. In the Cloud console, **APIs & Services → Domain verification → Add domain** and enter
   `florida-swaraj.fly.dev`. Channels are registered on the next watch pass (startup, then every
   6 h); the redeploy from step 2 triggers one.

## API

All `/api/*` routes need `Authorization: Bearer <API_TOKEN>`.

```sh
export PUBLIC_URL=https://florida-swaraj.fly.dev API_TOKEN=...

# Everything (first sync). Later pass the returned cursor: /api/sync?since=<cursor>
curl -s "$PUBLIC_URL/api/sync" -H "authorization: Bearer $API_TOKEN" | jq .

# Create or replace a task (the id is client-generated), get its placements back
curl -s -X PUT "$PUBLIC_URL/api/tasks/$(uuidgen | tr A-Z a-z)" \
  -H "authorization: Bearer $API_TOKEN" -H 'content-type: application/json' \
  -d '{
    "categoryId": "inbox",
    "title": "Write the quarterly report",
    "durationMinutes": 90,
    "minChunkMinutes": 30,
    "priority": "high",
    "deadlineType": "soft",
    "dueAt": "2026-11-13T00:00:00Z"
  }' | jq .

curl -s -X DELETE "$PUBLIC_URL/api/tasks/<id>" -H "authorization: Bearer $API_TOKEN"
curl -s -X POST "$PUBLIC_URL/api/schedule/run" -H "authorization: Bearer $API_TOKEN" | jq .
curl -s "$PUBLIC_URL/api/google/accounts" -H "authorization: Bearer $API_TOKEN" | jq .
curl -s -X PATCH "$PUBLIC_URL/api/calendars/<id>" -H "authorization: Bearer $API_TOKEN" \
  -H 'content-type: application/json' -d '{"selected": false}'
curl -s -X POST "$PUBLIC_URL/api/google/sync" -H "authorization: Bearer $API_TOKEN" | jq .
# Full re-download of every selected calendar (e.g. to backfill event columns after a deploy)
curl -s -X POST "$PUBLIC_URL/api/google/resync" -H "authorization: Bearer $API_TOKEN" | jq .
```

| Route | Purpose |
| --- | --- |
| `GET /health` | Liveness, no auth, no database access. |
| `GET /api/sync?since=` | `{ cursor, schedules, categories, tasks, events, placements, unscheduled, accounts, calendars }`. The first four hold rows with `updatedAt > since` (all rows without `since`), including soft-deleted tombstones; `events` holds only selected calendars' events plus tombstones. `placements`, `unscheduled` (`{ taskId, reason, unplacedMinutes, computedAt }`), `accounts` and `calendars` are always complete (and never contain tokens). Events carry `description`, `conferenceUrl`, `attendees`, `organizer`, `eventType`, `recurringEventId` and `icalUid`. |
| `GET /api/events` | Server-sent events: `connected` on open, then one `changed` event after every scheduler run or calendar sync. Clients respond by calling `/api/sync` with their cursor. Keep-alive comment every 25 s. |
| `PUT/DELETE /api/tasks/:id`, `/api/categories/:id`, `/api/schedules/:id` | Upsert / soft-delete, then rerun the scheduler. Responses include `scheduling: { placements, unscheduled, late }`. The `inbox` category cannot be deleted or renamed (400); deleting another category first moves its tasks to `inbox`. |
| `GET /api/tasks/:id`, `/api/categories/:id`, `/api/schedules/:id` | The row exactly as `/api/sync` sends it, tombstones included; 404 only for an id that never existed. |
| `POST /api/schedule/run` | Rerun the scheduler. |
| `POST /api/ai/parse-task` | `{ text, now?, timeZone? }` → `{ draft }`: Claude turns one line of text into a task draft (`title, notes, durationMinutes, minChunkMinutes, priority, deadlineType, dueAt, startAt, pinnedStart, categoryId, rationale`). The client reviews the draft and then `PUT`s the task itself. `timeZone` defaults to the first schedule's zone. 503 without `ANTHROPIC_API_KEY`; 502 when the model call fails. |
| `POST /api/ai/suggest-category` | `{ title, notes? }` → `{ categoryId, rationale }`: Claude picks the category the user would file the task under (never `inbox`; `null` when none fits). 503 without `ANTHROPIC_API_KEY`; 502 when the model call fails. |
| `POST /mcp` | Model Context Protocol endpoint for agents (same bearer token). See below. |
| `GET /api/google/accounts` | Accounts and calendars (never tokens). |
| `PATCH /api/calendars/:id` | `{ selected }` toggles whether a calendar blocks time and reaches the apps. Deselecting tombstones its events; selecting re-downloads it in the background. |
| `POST /api/google/sync` | Sync every selected calendar now, then reschedule. |
| `POST /api/google/resync` | Drop every selected calendar's sync token and run a full sync, rewriting every event row. |
| `GET /auth/google/start?label=&key=` | Browser entry point for connecting an account. |
| `POST /webhooks/google` | Google push notifications (validated by channel id + token). |

Dates cross the wire as ISO 8601 strings. Events keep `updatedAt` as the server's write time so
sync cursors never miss a change.

## MCP

`POST /mcp` speaks [MCP](https://modelcontextprotocol.io) over Streamable HTTP in stateless JSON
mode: no sessions, no SSE stream, one JSON-RPC response per request (`GET`/`DELETE /mcp` answer
405). It needs the same `Authorization: Bearer <API_TOKEN>` header as `/api/*`, and every tool
runs against the same store and scheduler as the apps, so a change made by an agent reaches the
apps through `/api/events` like any other.

Client configuration (Claude Code, Amp, Cursor and friends accept this shape):

```json
{
  "mcpServers": {
    "florida": {
      "type": "http",
      "url": "https://florida-swaraj.fly.dev/mcp",
      "headers": { "Authorization": "Bearer <API_TOKEN>" }
    }
  }
}
```

| Tool | Does |
| --- | --- |
| `list_categories` | Live categories with their `scheduleId`. |
| `list_tasks` | Open tasks (soonest due first) with their scheduled blocks; `categoryId?`, `includeCompleted?`, `limit?`. |
| `get_task` | One task with its blocks. |
| `create_task` | `categoryId`, `title`, and any task field; `id` defaults to a UUID, `durationMinutes` to 30, `priority` to `medium`, `deadlineType` to `soft` when `dueAt` is set, else `none`. Reschedules; returns the task's blocks plus `unscheduled`/`late`. |
| `update_task` | `id` plus any task fields; omitted fields stay, `null` clears. Reschedules. |
| `complete_task` / `delete_task` | Mark done (credits the full duration) / tombstone. Reschedule. |
| `get_agenda` | `date?` (YYYY-MM-DD) and `timeZone?`: that day's events from selected calendars (all-day first) (with `description`, `conferenceUrl` and `attendees`) and planned task blocks with titles. Defaults to today in the first schedule's zone. |
| `run_scheduler` | Rerun and return every placement. |

Bad references (`unknown categoryId x`, `task x not found`) and invalid arguments come back as
tool errors (`isError: true`) with a readable message, so the model can correct itself.

```sh
# Smoke test without a client
curl -s "$PUBLIC_URL/mcp" -H "authorization: Bearer $API_TOKEN" \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_agenda","arguments":{}}}' | jq .
```
