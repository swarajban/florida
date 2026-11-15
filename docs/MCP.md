# Florida — MCP & Agent Handoff Guide

Florida is Swaraj's single-user personal calendar and auto-scheduling task planner (his custom Motion replacement), hosted at `https://florida-swaraj.fly.dev`.

This document gives an AI agent everything needed to connect to Florida over MCP, read Swaraj's agenda and task backlog, and create or update tasks, projects, and day overrides without breaking Florida's scheduling invariants.

---

## 1. Connecting over MCP

Florida exposes a **stateless Streamable HTTP MCP endpoint** directly on the production server:

- **Endpoint:** `https://florida-swaraj.fly.dev/mcp`
- **Transport:** Streamable HTTP (`POST` JSON-RPC `2025-03-26`, JSON responses; no SSE session required—`GET /mcp` and `DELETE /mcp` return `405` by design)
- **Authentication:** `Authorization: Bearer <FLORIDA_API_TOKEN>` (same bearer token as `/api/*`, stored as `API_TOKEN` in Fly / Capy secrets)

### Ready-to-paste MCP client config (Streamable HTTP)

For clients that support remote HTTP MCP servers natively (Claude Code, Cursor, Capy, OpenAI/Codex MCP, Windsurf):

```json
{
  "mcpServers": {
    "florida": {
      "type": "http",
      "url": "https://florida-swaraj.fly.dev/mcp",
      "headers": {
        "Authorization": "Bearer ${FLORIDA_API_TOKEN}"
      }
    }
  }
}
```

### Fallback for stdio-only MCP clients (e.g. local desktop clients without HTTP headers)

```json
{
  "mcpServers": {
    "florida": {
      "command": "npx",
      "args": [
        "-y",
        "mcp-remote",
        "https://florida-swaraj.fly.dev/mcp",
        "--header",
        "Authorization: Bearer ${FLORIDA_API_TOKEN}"
      ],
      "env": {
        "FLORIDA_API_TOKEN": "<paste-token-here>"
      }
    }
  }
}
```

### Quick sanity check

Calling `tools/list` returns 16 tools (`list_categories`, `list_tasks`, `get_task`, `create_task`, `update_task`, `complete_task`, `delete_task`, `list_projects`, `create_project`, `update_project`, `delete_project`, `set_day`, `clear_day`, `get_brief`, `get_agenda`, `run_scheduler`). `GET https://florida-swaraj.fly.dev/health` is unauthenticated and returns `{"ok":true}`.

---

## 2. Core Mental Model & Scheduling Rules (Read Before Writing)

Every task/project/day mutation automatically reruns the scheduler on the server and returns the updated placements and any scheduling issues (`unscheduled`, `late`).

### Time zone and date conventions
- **Home time zone:** `America/Los_Angeles`.
- **Calendar dates** (`date`, `startDate`, `endDate`): `YYYY-MM-DD` in `America/Los_Angeles` (e.g. `"2026-11-16"`).
- **Timestamps** (`dueAt`, `startAt`, `pinnedStart`, `completedAt`): ISO 8601 UTC strings (e.g. `"2026-11-18T01:00:00.000Z"`).
- **Day-only due dates:** When Swaraj specifies a date without a clock time (e.g. *"due Tuesday"*), set `dueAt` to **17:00 local time** in `America/Los_Angeles` (for example `2026-11-17T17:00:00-08:00` → `"2026-11-18T01:00:00.000Z"`). Florida's apps display 17:00-local due dates cleanly as day-only labels.

### Categories, Inbox ("needs triage"), and Someday
1. **Always call `list_categories` first** in a session to get real `categoryId` values and their `area` (`"work"` or `"personal"`). Never invent category IDs. The built-in unfiled category ID is `"inbox"`.
2. **What counts as Inbox:** In Florida, Inbox means **"needs triage"**. A task is in Inbox if:
   - `categoryId === "inbox"`, **OR**
   - it has a real category **and** `dueAt == null && startAt == null && pinnedStart == null && someday === false`.
   *(Calling `list_tasks({ categoryId: "inbox" })` returns all untriaged tasks across both cases; calling `list_tasks({ categoryId: "<other>" })` excludes untriaged tasks.)*
3. **Choosing between Inbox, Scheduled, and Someday:**
   - **Quick dump / needs triage later:** `categoryId: "inbox"`, no dates (`someday: false`). Note: ordinary Inbox tasks **do** still get auto-scheduled onto the plan until triaged.
   - **Active task to auto-schedule:** set a real `categoryId` **plus** at least one of `dueAt`, `startAt`, or `pinnedStart` (`someday: false`).
   - **Backlog / no target date ("Someday"):** set a real `categoryId` **and** `someday: true`. Someday tasks exit Inbox and are **never scheduled** onto the calendar until given a date or toggled off Someday.
4. **Someday interactions on edits:**
   - Setting `someday: true` automatically clears `dueAt` and `pinnedStart`, sets `deadlineType: "none"`, and keeps `startAt` if present.
   - Changing `dueAt`, `startAt`, or `pinnedStart` to a new non-null timestamp automatically clears `someday` back to `false` unless `someday: true` is explicitly passed in the same call.

### Source links (`source`)
Whenever a task originates from a URL (GitHub PR/issue, Linear issue, Slack thread, web page, or `mailto:` link), attach it in `source`:
```json
{
  "url": "https://github.com/swarajban/florida/pull/38",
  "title": "Speed up CI workflows"
}
```
Florida derives `kind` (`"github" | "linear" | "slack" | "email" | "web"`) automatically from the URL and derives a title if omitted. On `update_task`, **omit** `source` to keep the existing link; pass `source: null` only to remove it.

### Contexts, routines, and day overrides
- Tasks have `context`: `"computer"` (default), `"errand"`, `"home"`, or `"office"`.
- Swaraj's weekday routine defines when each context can run (plus commitments like Gym).
- `set_day({ date: "YYYY-MM-DD", kind: "home" | "office" | "off", note? })` overrides a single date's routine (`"off"` clears routine work and commitments for that day; `clear_day` restores the weekday default).
- All-day calendar events (holidays, trips, hotel stays) automatically protect/block days when appropriate (leaving multi-day trips' checkout/return day open by default).

---

## 3. MCP Tool Reference (16 Tools)

### Reading the day & plan

| Tool | Arguments | What it returns |
|---|---|---|
| `get_agenda` | `{ date?: "YYYY-MM-DD", timeZone?: string }` | One day's full picture (defaults to today in `America/Los_Angeles`): calendar events from selected calendars (all-day first), scheduled task blocks (parallel blocks carry a `lane`), reserved project blocks, commitments (e.g. gym), and any `dayOverride`. |
| `get_brief` | `{}` | Latest stored morning daily brief and weekly review (if generated). |
| `list_categories` | `{}` | All live categories with `id`, `name`, `area` (`"work" \| "personal" \| null`), `color`, and `scheduleId`. |
| `list_tasks` | `{ categoryId?: string, includeCompleted?: boolean (false), limit?: 1..200 (50) }` | Open tasks (soonest `dueAt` first, undated last) with their scheduled blocks. Pass `categoryId: "inbox"` for everything needing triage. |
| `get_task` | `{ id: string }` | One task by ID plus its scheduled blocks. |
| `list_projects` | `{ status?: "thinking" \| "active" \| "on_hold" \| "done" }` | Live projects with status, `nextStep`, `weeklyMinutes`, `parallel`, and open task counts. |
| `run_scheduler` | `{}` | Forces a full reschedule across all open tasks and returns placements + unscheduled/late summaries. (Usually unnecessary after writes, which reschedule automatically.) |

### Creating & updating tasks

- **`create_task`** — Required: `categoryId`, `title`.
  - Defaults: `durationMinutes: 30`, `priority: "medium"`, `context: "computer"`, `someday: false`, `deadlineType: "soft"` when `dueAt` is provided (else `"none"`), `id`: auto-generated UUID (pass an explicit UUID for idempotent retries).
  - Optional fields:
    - `notes`: `string | null`
    - `source`: `{ url: string, title?: string } | null`
    - `durationMinutes`: integer `>= 1` (total estimated minutes)
    - `minChunkMinutes`: integer `>= 1 | null` (minimum splittable block size; omit/null if unsplittable or default)
    - `priority`: `"asap" | "high" | "medium" | "low"`
    - `deadlineType`: `"hard" | "soft" | "none"`
    - `dueAt`, `startAt`, `pinnedStart`: ISO 8601 string `| null` (`pinnedStart` locks the task to that exact time as a single block)
    - `someday`: `boolean`
    - `context`: `"computer" | "errand" | "home" | "office"`
    - `projectId`: `string | null`
    - `attention`: `"full" | "shared" | null` (`"shared"` allows running alongside parallel work)
    - `recurrence`: `{ frequency: "day" | "week" | "month", interval: 1..999, timeZone: string, startDate: "YYYY-MM-DD", weekdays?: number[] (0=Sun..6=Sat, weekly only), dayOfMonth?: 1..31 (monthly only), endDate?: "YYYY-MM-DD" | null } | null`
- **`update_task`** — Required: `id`, plus any subset of task fields above.
  - **Patch semantics:** omitted fields are preserved; passing `null` clears a nullable field.
  - **Recurring tasks:** editing template/rule fields updates this and future unfinished occurrences (pass `expectedRecurrenceRevision` from the task row if guarding concurrent edits); passing `recurrence: null` stops future repeats while keeping the current occurrence.
- **`complete_task`** — `{ id: string }`. Marks **only this occurrence** done right now, credits remaining duration, and reschedules remaining work. Recurring series keep future occurrences.
- **`delete_task`** — `{ id: string }`. Soft-deletes (tombstones) the task and reschedules. **Warning:** on a recurring task, `delete_task` also stops the series and deletes future unfinished occurrences (completed history stays). Use `complete_task` when Swaraj finished an occurrence.

### Managing projects

- **`create_project`** — `{ name: string, id?: string, status?: "thinking" | "active" | "on_hold" | "done", categoryId?: string | null, notes?: string | null, nextStep?: string | null, parallel?: boolean, weeklyMinutes?: number | null, sortOrder?: number | null }`
- **`update_project`** — `{ id: string, ...partial fields }`. Setting `status` to `"on_hold"`, `"thinking"`, or `"done"` immediately pulls all of that project's tasks off the scheduled plan without losing them; `"active"` schedules them again.
- **`delete_project`** — `{ id: string }`. Tombstones the project and leaves its tasks unfiled (`projectId = null`). Prefer `status: "done"` or `"on_hold"` unless Swaraj explicitly wants the project deleted.

### Day routine overrides

- **`set_day`** — `{ date: "YYYY-MM-DD", kind: "home" | "office" | "off", note?: string | null }`
- **`clear_day`** — `{ date: "YYYY-MM-DD" }`

---

## 4. Companion HTTP Endpoints (When MCP Tools Aren't Enough)

Calendar event writes, all-day blocking overrides, Google Calendar sync, and server-side AI helpers are not yet exposed as MCP tools, but use the **exact same base URL and `Authorization: Bearer <FLORIDA_API_TOKEN>` header**:

- **Create or update a Google Calendar event:**
  `PUT https://florida-swaraj.fly.dev/api/events/<uuid>`
  Body: `{ "calendarId": "<google-calendar-id>", "summary": "Title", "location": null, "description": null, "startAt": "<ISO>", "endAt": "<ISO>", "allDay": false, "blocksDay": null }`
  *(For all-day events, `startAt` and `endAt` are UTC midnights `YYYY-MM-DDT00:00:00.000Z` with exclusive `endAt`. Find writable `calendarId` values via `GET /api/google/accounts`.)*
- **Override whether an all-day event blocks scheduling ("Blocks my day"):**
  `PATCH https://florida-swaraj.fly.dev/api/events/<event-id>`
  Body: `{ "blocksDay": true }` (force block), `{ "blocksDay": false }` (force free), or `{ "blocksDay": null }` (revert to automatic judgment). Local to Florida; never modifies Google Calendar.
- **Delete a calendar event occurrence:**
  `DELETE https://florida-swaraj.fly.dev/api/events/<event-id>`
- **Trigger immediate Google Calendar sync:**
  `POST https://florida-swaraj.fly.dev/api/google/sync`
- **Parse natural-language task text into a structured draft (without saving):**
  `POST https://florida-swaraj.fly.dev/api/ai/parse-task` with `{ "text": "...", "timeZone": "America/Los_Angeles" }`
- **Generate a fresh AI brief:**
  `POST https://florida-swaraj.fly.dev/api/ai/brief` with `{ "kind": "daily" }` or `{ "kind": "weekly" }`

---

## 5. Agent Workflow Cheatsheet

1. **Morning / "What's my day look like?"**
   Call `get_agenda({})` and `list_tasks({ categoryId: "inbox" })`. Summarize fixed meetings, scheduled task blocks, protected/day-off status, and any Inbox items needing triage.
2. **"Add a task to..."**
   Call `list_categories({})` if not cached → pick the matching `categoryId` → decide Scheduled (has `dueAt`/`startAt`/`pinnedStart`), Someday (`someday: true`, no due date), or Inbox (`categoryId: "inbox"`) → include `source: { url, title }` if a link was shared → call `create_task` and report where Florida scheduled its block (or flag if `unscheduled` / `late` is non-empty!).
3. **"I'm taking Friday off / working from home Thursday"**
   Call `set_day({ date: "YYYY-MM-DD", kind: "off" | "home" | "office" })` and report any tasks that became `late` or `unscheduled` after the reschedule.
4. **"Pause project X for a week"**
   Call `update_project({ id, status: "on_hold" })` rather than deleting tasks or clearing dates.
