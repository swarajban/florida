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

Calling `tools/list` returns 30 tools (the reference below lists them). `GET https://florida-swaraj.fly.dev/health` is unauthenticated and returns `{"ok":true}`. These tools require the Wave 2 server version; a server not yet deployed may advertise fewer tools.

---

## 2. Core Mental Model & Scheduling Rules (Read Before Writing)

Every task/project/day mutation automatically reruns the scheduler on the server and returns the updated placements and any scheduling issues (`unscheduled`, `late`).

### Time zone and date conventions
- **Home time zone:** `America/Los_Angeles`.
- **Calendar dates** (`date`, `startDate`, `endDate`): `YYYY-MM-DD` in `America/Los_Angeles` (e.g. `"2026-11-16"`).
- **Timestamps** (`dueAt`, `startAt`, `pinnedStart`, `completedAt`, `waitingUntil`): ISO 8601 UTC strings (e.g. `"2026-11-18T01:00:00.000Z"`). MCP also accepts `waitingUntil: "YYYY-MM-DD"`, meaning midnight at the start of that day in the user's settings time zone. HTTP writes require an ISO instant.
- **Day-only due dates:** When Swaraj specifies a date without a clock time (e.g. *"due Tuesday"*), set `dueAt` to **17:00 local time** in `America/Los_Angeles` (for example `2026-11-17T17:00:00-08:00` → `"2026-11-18T01:00:00.000Z"`). Florida's apps display 17:00-local due dates cleanly as day-only labels.

### Categories, Inbox ("needs triage"), and Someday
1. **Always call `list_categories` first** in a session to get real `categoryId` values and their `area` (`"work"` or `"personal"`). Never invent category IDs. The built-in unfiled category ID is `"inbox"`.
2. **What counts as Inbox:** In Florida, Inbox means **"needs triage"**. A task is in Inbox if:
   - `categoryId === "inbox"`, **OR**
   - it has a real category **and** `dueAt == null && startAt == null && pinnedStart == null && someday === false && waitingOn == null`.
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

### Tags and waiting follow-ups

Tasks carry `tags: string[]` (default `[]`), `waitingOn: string | null`, and `waitingUntil: ISO timestamp | null`. These fields round-trip through every task response, HTTP sync, and the offline Apple store; the app editors are a separate UI rollout.

- Tags are free-form: entries are trimmed, lowercased, empty entries dropped, and duplicates removed in first-seen order. At most 30 normalized tags of at most 64 characters each are accepted. Omit `tags` to preserve them on edits, or send `[]` to clear them; `null` is invalid.
- `waitingOn` describes the person or blocker (trimmed, at most 500 characters); empty/whitespace becomes `null`. A waiting task has no pin: setting a blocker clears `pinnedStart`, preserves `startAt` and the due date, and leaves `someday` unchanged. In a real category, waiting counts as an explicit triage decision.
- Without `waitingUntil`, waiting tasks have no placements, optional suggestions, or unscheduled warnings. A dated follow-up makes the earliest schedulable instant the later of `startAt`, `waitingUntil`, and now. Follow-ups at or beyond the horizon end remain parked without an unscheduled warning. After the follow-up is eligible, scheduling and deadline warnings work normally, but `waitingOn` remains set until explicitly cleared.
- Send `waitingOn: null` (or a blank string) to clear the blocker and its follow-up together. A follow-up without a non-empty blocker is rejected; an update can omit `waitingOn` if the task already has a blocker. Clearing the blocker never restores a removed pin. Someday and inactive projects still keep the task off the plan.
- Recurring tasks copy tags and the blocker to future unfinished occurrences, shifting the follow-up by local calendar dates like `startAt`. Completion affects only that occurrence, not the next one's blocker.

Example: `create_task({ categoryId: "work", title: "Follow up on approval", tags: ["client", "approval"], waitingOn: "Alice", waitingUntil: "2026-11-20" })`. All single writes, batch variants, and `dryRun` previews use these same rules.

### Contexts, routines, and day overrides
- Tasks have `context`: `"computer"` (default), `"errand"`, `"home"`, or `"office"`.
- Swaraj's weekday routine defines when each context can run (plus commitments like Gym).
- `set_day({ date: "YYYY-MM-DD", kind: "home" | "office" | "off", note? })` overrides a single date's routine (`"off"` clears routine work and commitments for that day; `clear_day` restores the weekday default).
- All-day calendar events (holidays, trips, hotel stays) automatically protect/block days when appropriate (leaving multi-day trips' checkout/return day open by default).

---

## 3. MCP Tool Reference (30 Tools)

Task objects returned by MCP carry a computed `appUrl`, for example `florida://tasks/<id>`; project objects carry `florida://projects/<id>`. Agenda task blocks also include the task's `appUrl`. These links do not change the HTTP sync payload. Opening them requires a compatible Florida app handler.

### Reading the day & plan

| Tool | Arguments | What it returns |
|---|---|---|
| `get_agenda` | `{ date?: "YYYY-MM-DD", timeZone?: string }` | One day's full picture (defaults to today in `America/Los_Angeles`): calendar events from selected calendars (all-day first), scheduled task blocks (parallel blocks carry a `lane`), reserved project blocks, commitments (e.g. gym), and any `dayOverride`. |
| `get_range` | `{ startDate: "YYYY-MM-DD", endDate: "YYYY-MM-DD" }` | Inclusive range of 1–31 days in the settings/default time zone. Returns `{ startDate, endDate, timeZone, days }`; each day has exactly the `get_agenda` shape, including zoned `start`/`end`, events, task blocks, project time, commitments, and override. Reversed or oversized ranges are errors. |
| `get_brief` | `{}` | Latest stored morning daily brief and weekly review (if generated). |
| `list_categories` | `{}` | All live categories with `id`, `name`, `area` (`"work" \| "personal" \| null`), `color`, and `scheduleId`. |
| `list_tasks` | `{ categoryId?, includeCompleted?, limit?, query?, dueBefore?, dueAfter?, context?, projectId?, priority?, someday?, scheduledOn?, hasSource?, tag?, tags?, waiting? }` | Open tasks (soonest `dueAt` first, undated last) with scheduled blocks. Filters combine with AND; see below. `includeCompleted` defaults to false; `limit` is 1–200, default 50. |
| `get_task` | `{ id: string }` | One task by ID plus its scheduled blocks. |
| `list_projects` | `{ status?: "thinking" \| "active" \| "on_hold" \| "done" }` | Live projects with status, `nextStep`, `weeklyMinutes`, `parallel`, and open task counts. |
| `run_scheduler` | `{}` | Forces a full reschedule across all open tasks and returns placements + unscheduled/late summaries. (Usually unnecessary after writes, which reschedule automatically.) |

### Task search and filters

- `query`: case-insensitive literal substring of title OR notes; trimmed, with blank text ignored. `%` and `_` are literal characters, not wildcards.
- `dueAfter` / `dueBefore`: inclusive ISO timestamps (explicit offset or `Z`), or `YYYY-MM-DD`. A date means start of day for `dueAfter`, and the entire day for `dueBefore`, in the user's settings/default time zone. Undated tasks never match either bound. Local days can be 23 or 25 hours at DST transitions.
- `context`: `"computer" | "errand" | "home" | "office"`; `priority`: `"asap" | "high" | "medium" | "low"`. These are Florida's actual enums, not `critical`, `phone`, or `anywhere`.
- `projectId`: a UUID, or `"none"` / `null` for tasks without a project; omission means any project.
- `someday`: exact boolean match; `hasSource`: true for a non-empty source URL, false for absent/empty source.
- `tag`: one trimmed/lowercase tag; `tags`: all specified normalized tags must be present (an empty array adds no restriction). Both filters can be combined, and tag comparisons are exact, not substrings.
- `waiting`: `true` matches a non-null blocker, even after its follow-up date; `false` matches no blocker.
- `scheduledOn`: `YYYY-MM-DD` in the settings/default time zone. Matches any placement overlapping that day, or a `pinnedStart` inside the day. Day end is exclusive.

Example: `list_tasks({ query: "proposal", dueBefore: "2026-11-20", context: "computer", projectId: "none", someday: false, hasSource: true })`.

### Creating & updating tasks

- **`create_task`** — Required: `categoryId`, `title`.
  - Defaults: `durationMinutes: 30`, `priority: "medium"`, `context: "computer"`, `someday: false`, `deadlineType: "soft"` when `dueAt` is provided (else `"none"`), `id`: auto-generated UUID (pass an explicit UUID for idempotent retries).
  - Optional fields:
    - `notes`: `string | null`
    - `source`: `{ url: string, title?: string } | null`
    - `tags`: `string[]` (normalized; see above)
    - `waitingOn`: `string | null`
    - `waitingUntil`: ISO 8601 timestamp, `YYYY-MM-DD`, or `null` (requires a non-empty blocker)
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
- **`list_deleted_tasks`** — `{ query?: string, limit?: 1..200 }`, default limit 50. Returns tombstoned task objects with `appUrl`, newest `deletedAt` first. Search has the same title/notes semantics as `list_tasks`.
- **`restore_task`** — `{ id: string }`. Clears one task's tombstone, reschedules, and returns `{ task, scheduling: { unscheduled, late } }`, with placements and `appUrl` on the task. If its category was deleted, the restored task moves to Inbox. Already-live tasks succeed idempotently; unknown IDs are errors. Restoring a recurring occurrence does **not** restart its stopped series or restore other deleted occurrences.
- **`parse_task`** — `{ text: string, now?: ISO timestamp, timeZone?: IANA zone }`. Returns `{ draft }` using live category examples and active projects, without saving or scheduling anything. Text is trimmed and limited to 1–2000 characters; the clock and settings/default zone are used when omitted. If AI is not configured, returns a clear tool error; review the draft before calling `create_task`.

### Availability, previews, change history, and batch writes

- **`find_free_slots`** — `{ windowStart, windowEnd, durationMinutes, context?, deadline?, includeScheduledTasks?: true, limit?: 20 }`. Bounds and optional deadline accept ISO instants or `YYYY-MM-DD` in the settings time zone. A start date means local midnight; end/deadline dates include the entire day. The effective range must be positive and at most 31 elapsed days. Duration is a positive integer; limit is 1–100. Omitted context accepts any active routine work window; a context restricts eligibility. Returns `{ timeZone, slots: [{ startAt, endAt, durationMinutes }] }`: maximal contiguous windows at least the requested duration long. Calendar blocking policy, day overrides, blocking all-day events and commitments always apply. Task/project placements in all lanes are also subtracted unless `includeScheduledTasks: false`. Settled commitments are preserved inside the stored horizon, including searches crossing its edge; uncovered time uses calculated commitments. Optional hours and hard-deadline overflow are excluded. The tool is read-only and does not refresh a stale plan.
- **Write previews:** `create_task`, `update_task`, `set_day`, and `update_project` accept `dryRun: true`. The server applies the same validation and recurrence behavior, computes the proposed plan inside one transaction, and rolls everything back before responding. No entity, recurrence, placement, journal row, database sync timestamp, Google write, or SSE notification persists. Responses keep the usual entity and add full proposed `scheduling`, `changes`, `newlyLate`, and `newlyUnscheduled`. The latter two contain only tasks not already late/unscheduled in the stored baseline before the hypothetical write; the full scheduling result still includes all warnings. Preview IDs are provisional unless supplied. A preview is not a reservation: a later write recomputes from current state. Normal writes return the usual scheduling summary plus the same change/warning-diff fields and `dryRun: false`.
- **`batch_create_tasks`** — `{ tasks: [<create_task arguments>, ...], dryRun?: false }`.
- **`batch_update_tasks`** — `{ tasks: [{ id, ...taskPatch }, ...], dryRun?: false }`.
- **`batch`** — `{ operations: [{ tool, arguments }, ...], dryRun?: false }`. Supported tools: `create_task`, `update_task`, `complete_task`, `delete_task`, `create_project`, `update_project`, `delete_project`, `set_day`, `clear_day`. Google/network writes are excluded. Every batch contains 1–100 operations. Mutations execute in order with the scheduler run exactly once at the end of the same transaction. Validation, reference, or scheduling failure rolls back all changes. SSE publishes once, after commit, and never for previews. Responses contain ordered `results` with the usual entity snapshots and final task placements, a scheduling summary, and changes/warning diffs. All three batch tools support rollback-only previews. Use explicit IDs for retryable creations; retrying without IDs creates new tasks.
- **`list_changes`** — `{ since: ISO timestamp, limit?: 1..200, cursor?: { tasks?: { at, id }, projects?: { at, id }, placements?: { at, id } } }`, default limit 100 **per collection**. Returns `{ tasks, projects, placements, hasMore, nextCursor, since }`. Task/project entries are current changed snapshots (not a field-by-field audit log), including tombstones, `changeType`, timestamps, and `appUrl`. Task types are `created`, `updated`, `completed`, `deleted`; projects omit `completed`. Placement entries record changed future intervals or unscheduled state: `taskId`, `title`, `appUrl`, `changeType` (`created`, `moved`, `removed`, `unscheduled`), `previousPlacements`, `newPlacements`, `previousUnscheduled`, `newUnscheduled`, `unscheduledReason`, `reason`, and `changedAt`. Unchanged scheduler runs add nothing. Reasons identify the initiating task/project/day/event write, Google sync, or manual run; they describe the trigger rather than claiming which individual constraint caused each downstream move. The server-only journal starts at Wave 2 deployment, is pruned after 30 days during scheduling, and is never added to Apple sync payloads. Keep the original `since` while following `nextCursor` until `hasMore` is false, then save the final returned `since` as the next watermark. Keyset pagination handles equal timestamps; the sync fence excludes in-flight transactions.

### Calendar tools

- **`list_calendars`** — `{}`. Returns `{ accounts, calendars, writableCalendarIds }`; accounts also contain their calendars. Credentials, sync tokens, and channel secrets are never included. Writable IDs are Florida calendar IDs with `selected: true` and `accessRole: "owner" | "writer"`; unselected calendars cannot be written through Florida.
- **`upsert_event`** — Required: `{ calendarId, summary, startAt, endAt, allDay }`; optional `id` must be a UUID (generated when omitted). Optional fields match the event HTTP API: `location`, `description`, tri-state `blocksDay`, `responseStatus` (`accepted`, `declined`, `tentative`, `needsAction`), `recurrence` (`{ frequency: daily|weekly|monthly|yearly, interval: 1..99, timeZone, count?: 1..999 }`), and `scope: "instance" | "series"`. Writes through Google, then returns `{ event, scheduling: { unscheduled, late } }`. Reuse a chosen UUID to retry creation safely. `endAt` must be after `startAt`; all-day boundaries are UTC midnights, with exclusive end. Recurrence is creation-only; series edits obey the same restrictions as the HTTP API. A tombstoned event is an error, not a resurrection.
  Optional `attendees` accepts at most 50 email strings or objects `{ email, displayName?: string | null, optional?: boolean }`. Emails must be syntactically valid; they are trimmed, lowercased, and deduplicated in first-seen order. Omit `attendees` to leave guests unchanged; an explicit list replaces guests, and `[]` removes all guests except the live self/organizer entries, which are always preserved. Matching guests retain their live Google RSVP and name unless a non-empty replacement name is supplied; `optional` changes only when supplied. New guests receive invitations through Google (`sendUpdates=all`); changed guest lists notify guests too. Self `responseStatus` can be combined with a guest edit. An unchanged live attendee list isn't sent again.
- **`delete_event`** — `{ id: string }`. Deletes through Google and returns `{ deleted: id, scheduling }`. Already-deleted events succeed; unknown IDs are errors.
- **`set_event_blocks_day`** — `{ id: string, blocksDay: boolean | null }`. Local all-day override: true blocks, false frees, null restores automatic judgment. Returns `{ event, scheduling }`; timed or deleted events are errors. Does not write to Google.
- **`sync_google_calendar`** — `{}`. Awaits a Google sync, then reschedules and returns `{ scheduling: { unscheduled, late } }`. Like the HTTP endpoint, production sync is best-effort: individual calendar failures are logged server-side, so a scheduling response does not confirm that every calendar refreshed. Without a configured sync dependency, it only reschedules; event create/delete tools instead return a configuration error. Event-write Google refusals become readable MCP tool errors.

### Managing projects

- **`create_project`** — `{ name: string, id?: string, status?: "thinking" | "active" | "on_hold" | "done", categoryId?: string | null, notes?: string | null, nextStep?: string | null, parallel?: boolean, weeklyMinutes?: number | null, sortOrder?: number | null }`
- **`update_project`** — `{ id: string, ...partial fields }`. Setting `status` to `"on_hold"`, `"thinking"`, or `"done"` immediately pulls all of that project's tasks off the scheduled plan without losing them; `"active"` schedules them again.
- **`delete_project`** — `{ id: string }`. Tombstones the project and leaves its tasks unfiled (`projectId = null`). Prefer `status: "done"` or `"on_hold"` unless Swaraj explicitly wants the project deleted.

### Day routine overrides

- **`set_day`** — `{ date: "YYYY-MM-DD", kind: "home" | "office" | "off", note?: string | null }`
- **`clear_day`** — `{ date: "YYYY-MM-DD" }`

---

## 4. Companion HTTP Endpoints (When MCP Tools Aren't Enough)

These HTTP counterparts use the **same base URL and `Authorization: Bearer <FLORIDA_API_TOKEN>` header**. Prefer the MCP tools above for event writes, blocking overrides, calendar sync, and task parsing; fresh AI brief generation remains HTTP-only:

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
