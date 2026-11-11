# Florida — handoff (Nov 10)

Written at the end of [the build thread](https://ampcode.com/threads/T-01a1b9ee-199d-75e9-ae6f-ac6547974cd8) for whoever continues on a new thread from `main`. It covers the work of Nov 9–10: scheduling v2, the task editor and agenda pass, and the Mac jump mode. Everything under "State" was checked on Nov 10 after the last push; anything I only know second-hand says so.

This file is a copy of the [handoff artifact](https://ampcode.com/artifacts/florida-handoff-nov-10-0e2d7333-4a6e-4e97-bfaa-cdbec55748ec) in Amp, taken at its revision 2. The Amp links in it open only for Swaraj's account.

When sources disagree, trust them in this order: the code on `main`, then `README.md`, `apple/README.md` and `server/README.md`, then this file, then the older artifacts listed at the end.

## State

**Git**

- The last code commit on `main` is `8776b97`. The only commit after it adds this file. Nothing was uncommitted or unpushed when this was written.
- The last code push (Nov 10, about 23:57 UTC) added two commits, `5090c63` and `8776b97`: jump labels only on what is on screen. The push before it (about 22:50 UTC) added `69b8a71`, `77e68cd`, `8991afd`, `f11477c`.

**CI**

- `f11477c`: all six checks passed, including both TestFlight uploads.
- `8776b97`: the three workflows (CI, iOS, macOS TestFlight) were still running when this was written. Read their results on the [commit page](https://github.com/swarajban/florida/commit/8776b9756edb2e80d3e6641bf890de0e81c78e02) before building on it. The macOS workflow runs the whole Mac UI suite and uploads only if it passes.

**TestFlight** (app "Florida Tasks", App Store Connect app ID `6832337704`, bundle id `com.swarajban.florida` on both platforms)

- Newest processed builds: iOS **261** and Mac **71**, both VALID and in internal testing. They were built from `f11477c`, so Mac 71 has jump mode, `v` and the menu bar title, but it labels every item, on screen or not.
- The Mac build from `8776b97` will be the first with on-screen-only labels. Build numbers are `run_number * 10 + run_attempt`; the last steps were iOS 251 → 261 and Mac 61 → 71, so the next are probably iOS 271 and Mac 81.

**Server**

- Fly app `florida-swaraj`, region `lax`, release **v8**, image `git-7c65fa9`, one machine, health check passing, `/health` answers 200.
- Nothing under `server/`, `packages/` or `fly.toml` has changed since `7c65fa9`, so the deployed server is the server on `main`. No deploy is pending.
- Fly secrets that are set: `ANTHROPIC_API_KEY`, `API_TOKEN`, `DATABASE_URL`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `PUBLIC_URL`, `TOKEN_ENCRYPTION_KEY`.
- `GOOGLE_SITE_VERIFICATION` is not set. `server/README.md` says that without it Google's push registration fails and calendar changes arrive with the hourly poll. I did not check the logs to see which is happening.

**Tests**

- `pnpm test`, last run at `f11477c` in the orb: scheduler 95 tests, server 174 tests, all passing. No TypeScript has changed since.
- FloridaCore, run at `5090c63` in the orb: 221 tests in 21 suites, all passing.
- FloridaKit, last run at `f11477c`: 114 tests in 9 suites, all passing. It was not rerun after the FloridaCore change it depends on; CI's Linux job does that.
- Mac UI suite (3 tests): `testJumpLabelsInBothAppearances` passed on a Mac satellite on the files that are now `8776b97`. The other two last passed one edit earlier, before the change to how `CalendarGridView.swift` tracks a scroll that a key started. The macOS TestFlight workflow runs all three.
- The iOS app was not touched by the last two code pushes.

## How Swaraj works

Observed in the build thread, not rules he wrote down.

- He reads replies on his phone. Short, skimmable, answer first.
- Speed is the first requirement: "it should be fast to load, and never lag on any interaction". The UI never waits on the network.
- He tests TestFlight builds and sends feedback as short voice-style messages, often several in a row.
- He says "commit and push" for each batch. A push to `main` that touches `apple/` uploads an iOS and a Mac build, so each push has waited for his word.
- Server deploys are separate and by hand; he said "Deploy" for v8.
- Choices made for him get listed briefly so he can veto them.

## Project 1: Mac jump mode, `v`, and the menu bar title

Commits `69b8a71`, `77e68cd`, `8991afd`, `f11477c`, then `5090c63` and `8776b97` for on-screen-only labels. All but the last two are in TestFlight Mac 71.

**What he asked for**

- "vimcal had something cool where there was one key (maybe x?, check their docs?) where it would immediately layer a letter or number on every task/event on the calendar. if you typed that key, it would immediately select it. from there you could do things like edit tasks (mark done, edit dates, edit statuses) or edit calendar (reschedule, join meeting, edit rsvp)"
- "would have to be across that task bar too on the right (eg if task A is both on calendar and shown in task bar, they get the same keyboard shortcut label)"
- "also on macos menubar, can you put the date to the right of the next event name", then "plus also add time!"
- Asked two follow-up questions, he chose labels only on what is on screen, and the current clock time in the menu bar.

**What was built**

- `f` starts jump mode. Every task and event on screen, on the calendar and in the task pane, gets a short label; typing the label selects the item and leaves the mode. The usual keys then act on the selection: Space, `e`, `s`, `p` on a task; `⇧E`, `r y`, `v`, `o` on an event.
- Labels go to the calendar's items in `j`/`k` order first, then the task pane's (only when the pane is visible). Keys are the home row, then the other letters, then digits. Past 36 items, just enough keys from the end of the alphabet become the first key of two-key labels, so no label is the start of another.
- A task shown on the calendar and in the pane has one label. An evening suggestion is its own item with its own label, even when the same task is also planned by day.
- Free gaps get no label. The gym and project-time blocks do.
- "On screen" is decided at the moment `f` is pressed (since `8776b97`):
  - Time grid: a block counts when about 14 pt of it is inside the scrolled view. A block cut off at the top carries its badge at the top of the view.
  - All-day bars always count. The month view is not filtered, because it does not scroll.
  - Task pane: a row counts when its label strip is below the pinned section header and above the pane's bottom edge.
  - A task on screen in only one of the two places gets one label, drawn there.
  - Labels do not follow scrolling after `f`. A scroll that a key started and that is still animating counts as finished, so `G` then `f` labels where `G` lands.
- While labels are up: the first key of a two-key label narrows them; Esc cancels; any other key leaves the mode and is swallowed, so a mistyped label cannot delete or complete the previous selection; ⌘ shortcuts leave the mode and still run.
- `v` opens the meeting link of the selected event, or of the event in the open popover. Otherwise the status bar says "Select an event first" or "This event has no meeting link".
- Menu bar title is now "Standup in 8m · Tue Nov 10, 2026 8:52 AM", and the date and time alone when no meeting is left today.
- `apple/README.md` has rows for `f` and `v`, and now gives the month view as `⇧M` (on the Mac `m` is Move).

**Choices made for him, none objected to**

- `f`, not `x`: `x` is Delete in Florida. Vimcal's own key is unconfirmed; its docs name none, and a 2022 review only says `F` "shows all the hotkeys".
- He chose on-screen-only labels. How "on screen" is decided (cut-off blocks, labels not following a scroll, the month view unfiltered) was my choice, listed to him in the build thread after the push.
- A month day's hidden "+N more" lines get no label and never did: `GridLayout.build` puts only the shown lines in `orderedItems`.
- "Time" in the menu bar is the current clock time, not the event's start time. He confirmed this.

**Where the code is**

- Label logic: `apple/FloridaCore/Sources/FloridaCore/Keyboard/JumpLabels.swift`, tests in `Tests/FloridaCoreTests/Keyboard/JumpLabelsTests.swift` (17 tests, 6 of them for `JumpViewport`).
- Mode: `apple/macOS/App/AppModel+Jump.swift` (`startJump`, `handleJumpKey`, `jumpLabel(for:)`); state is `AppModel.jump`.
- Key routing: `AppModel+Keyboard.swift` calls `handleJumpKey` before the keymap. Bindings are in `apple/macOS/Keyboard/MacKeymap.swift` and `MacCommand.swift`.
- Drawing: `apple/macOS/Keyboard/JumpBadge.swift`; `TimeGridCanvas.swift` (`drawJumpLabels`), `AllDayStripView.swift`, `MonthGridView.swift`, `TaskRowView.swift`, `OptionalPicksViews.swift`.
- On-screen filter: `JumpViewport` (`shows`, `labelTop`) in `JumpLabels.swift`. `AppModel.gridVisibleRect`, `gridScrollTarget` and `paneItemsOnScreen` are unobserved model state, written by `apple/macOS/Calendar/CalendarGridView.swift` and by `tracksJumpVisibility` in `apple/macOS/Tasks/TaskPaneView.swift`. `startJump` reads them and stores `jumpGridViewport` for drawing. `JumpBadge.top` places the badge on a cut-off block; `GridGeometry.rows` gives a block's vertical range.
- `v`: `AppModel+Events.swift`. Menu bar: `AppModel+MenuBar.swift` (`menuBarTitle`), `MenuBar/MenuBarLabel.swift`.
- UI test: `testJumpLabelsInBothAppearances` in `apple/macOSUITests/SmokeTests.swift`. The grid is a `Canvas` the test cannot read, so it reads labels from task-pane rows with accessibility ids `task-jump-<task id>`. It also asserts that a task scrolled out of the pane has no label, then presses `G` on the calendar and `f` straight after. Its captures are named `jump-<appearance>` and `jump-scrolled-<appearance>`.

**Verified, on a Mac satellite with demo data**

- Light and dark captures: badges readable, none covers a title, grid and pane labels match.
- `v` opened Safari at the demo Standup's Meet link; both messages appeared.
- Two-key labels narrow and select, tested with a shortened 8-key alphabet (since restored).
- The menu bar title, read from the real status item in two time zones.
- On-screen-only labels, in the 3-day view: the UI test failed on the app before the change, at the assertion that an off-screen task has no label, and passes at `8776b97`. I looked at the two light captures from the final run. Unscrolled: labels only on visible items, grid and pane labels matching. After `G` then `f`: the cut-off Tue block has its badge at the top of the view, and the pane's labels continue the calendar's key order.

**Not verified**

- Anything with real Google data.
- The month view with the full 36-key alphabet (badges were only seen there in the shortened-alphabet run).
- The menu bar title beyond demo data.
- On-screen-only labels in the Day and Week views, after scrolling the grid by hand (only `G` was exercised), and the two dark captures of the final run, which I did not look at.

**Known limits of on-screen-only labels**

- After `g g` in the task pane, the first row sits under the pinned section header and gets no label. The build thread already filed a fix suggestion for this ("Keep selected task clear of pinned header").
- `TaskPaneView.pinnedHeaderHeight = 34` is my estimate of the pinned header's height, not a measured value.
- Nothing on this project is waiting on Swaraj.

## Project 2: task editor, category order, iOS agenda look

Commits `7c314d8`, `bddb97c`, `6b80eec`, `a837304`. In TestFlight iOS 251 and Mac 61.

**What he asked for** (shortened)

- Task page: "it's either, like, mark it as done or fiddle with the dates"; start and due "should be next to each other and near the top"; "if I change the start date to past the due date, the due date should be automatically bumped to ... one day after the new start date".
- Categories: "sort them to be, like, by area first, and then alphabetically, and then sort the work ones on top".
- Agenda: "hard to tell what is a calendar event versus what's a task"; tasks are "more a little bit like suggestions rather than, like, hard things".

**What was built**

- Both task editors open on Mark done, then title and notes, then a Dates section with Start, Due and Deadline together. The Mac label "Not before" became "Start".
- Moving the start to or past the due date moves due to the day after the new start, keeping a timed due date's clock time. A start on the same day as a whole-day due date leaves it alone. The rule is `TaskDay.due(_:notBefore:calendar:)` in `apple/FloridaCore/Sources/FloridaCore/Models/TaskDay.swift`.
- Every category list and picker in both apps shows Inbox, then work, then personal, then categories with no area, by name within each. The rule is `apple/FloridaCore/Sources/FloridaCore/Models/CategoryOrder.swift`, and the store returns categories already in that order.
- Manual reordering of categories was removed from both apps, since the order is derived. `sortOrder` stays on the wire, and the server and MCP still order by it, so `list_categories` over MCP can differ from the apps.
- In the iOS agenda list an event is a card filled in its calendar's color; a task block has no fill, a dashed bar (solid when pinned), an unticked circle and dimmer times. Files: `apple/iOS/Agenda/AgendaRows.swift`, `PlanRows.swift`, `OptionalPicksSection.swift`.
- Only the iOS agenda list was restyled. The iOS day grids and the Mac grid were not changed.

He accepted these by asking to commit and push, and has not sent feedback on builds 251 and 61 since.

## Project 3: scheduling v2

Commits `0679a33` through `7c65fa9`, Nov 9–10. Live: Fly v6 (step 1), v7 (step 2), v8 (steps 3–6); in every build since iOS 241 and Mac 51.

The plan and its eight decisions are in the [scheduling v2 proposal](https://ampcode.com/artifacts/florida-scheduling-v2-proposal-6d1de367-6e35-4581-a2b0-57b12579a604); the as-built notes are the "Scheduling v2" section of the [design doc](https://ampcode.com/artifacts/florida-design-e311c92e-0792-43c0-9fc7-c47d3b4d66b8). In short:

- **Routine and context (step 1).** One weekly routine in `America/Los_Angeles` replaced per-category schedules. Tables `routine_blocks` and `settings`. A task has a `context` (computer, errand, home, office) and a routine block lists the contexts it allows; time outside every block is never scheduled. A category has an `area` (work, personal, or none for Inbox). `schedules` stays on the wire for old clients and is ignored.
- **Evening suggestions (step 2).** A routine block can be `optional`. The plan never uses it; the scheduler lists suggestions for it (`optional_placements`), personal categories first. "Do tonight" pins the task.
- **Projects (step 3).** Status thinking, active, on hold or done; optional weekly budget; optional category. Only an active project's tasks are planned. A budget not covered by open tasks becomes hatched "project time" blocks.
- **Lanes (step 4).** Up to 3 shared-attention tasks of different projects run side by side, never beside full-attention work, meetings or commitments.
- **Gym and day kinds (step 5).** A routine block that allows nothing is a commitment. The gym also happens once a week in the first free office-morning slot (Tuesday 09:00, else Wednesday), and is reported missed when neither is free. A date can be made a home, office or off day (`day_overrides`).
- **Claude (step 6).** A daily brief, a weekly review and "Why here?" for one task, written from the scheduler's facts. Claude never places a task. Without `ANTHROPIC_API_KEY` the AI routes answer 503. The default model is `claude-sonnet-5-5` (`ANTHROPIC_MODEL`).

**Rules that came out of the review round** (four review subagents read steps 3–6 before the push; fixes are in `27a2327`, `b2eb53f`, `60f85ee`, `41235ba`)

- Every scheduler run replans all blocks still ahead; only a block underway at `now` stays put. Before this, every stored placement was fed back as `previous`, which is why Swaraj saw that "tasks don't reschedule on update".
- Busy time reaches back to the Sunday of the current week, so a gym session that moved off a booked Tuesday stays moved after the meeting ends.
- A shared block underway keeps its lane; a pinned task counts as taken time for commitments; alternates are tried in date order.
- Plan block ids are owner plus start time, so a selection survives the scheduler replacing the rows.
- The apps can run ahead of the server: schedule, category and project writes are pushed first, and a task filed under a project waits unsent while the server has no project route.
- Rolling the apps back to a build older than iOS 241 or Mac 51 is not safe: an older build cannot read a queued project write, and its sync stops.

**His two reports during this work**

- "tasks don't reschedule on update (at least on iOS)": fixed on the server in `b2eb53f`, as above.
- "I still don't see the context field on tasks": the context picker has been in both editors since `db76c9b`, and `41235ba` added the context to task rows.
- After builds 241 and 51 and the v8 deploy he wrote "latest build is looking good" and has not raised either again.

**Left from the reviews.** These come from the review and fix reports of Nov 10. They were not fixed then, and I have not re-checked them since.

- Mac: undoing a project change back to a project deleted since queues a write the server rejects ("unknown projectId").
- Mac: the project editor refuses to save a project deleted elsewhere, but still overwrites fields a sync changed while the sheet was open. iOS copies only the fields the draft changed.
- Mac: Set Day with the same kind on a day that already has an override rewrites it.
- FloridaKit: project time can show twice until the next pull when the device clock is ahead of the server's. The suggested fix was a pull after `runScheduler()` and `triggerGoogleSync()` in `SyncClient.swift`; today those two still apply the reply without pulling.
- Not settled because it needs a device: a Release build migrating the store to v6 while the app and the widget open it at the same time.
- Not seen on screen: three lanes in the iOS 3-day grid (about 38 pt each) or beside an event in a Mac week column (about 30 pt each); "Alongside …" captions at accessibility text sizes; whether `1`, `2`, Tab and Return still reach the Mac brief sheet after a click into its text.

**Two offers he never answered.** I have only a one-line note for each from an earlier summary, so ask him before building either.

- Ending the office gym slot at 10:00.
- The brief's wording for a task whose start date is in the future.

## Not built

Checked by searching the code on Nov 10.

- **APNs silent push.** No code. Widgets are only as fresh as the app's last sync. It needs an APNs key from Swaraj, and the `aps-environment` entitlement was removed from `project.yml` and must come back with it.
- **Slack saved items and Linear.** No code. Both are on his original list of future adds.
- **Scheduler on the device** (JavaScriptCore). No code.
- **Availability sharing on the Mac.** No code.
- **Deep links to one item.** Only `florida://agenda` and `florida://tasks` exist.
- **Out of office and focus time.** `eventType` is stored and synced, but `server/src/scheduling.ts` does not read it. All-day events do not block time.

Built and worth knowing about, since older docs call them future work: the MCP endpoint (`POST /mcp`, 16 tools, including projects, `set_day`, `clear_day` and `get_brief`), recurring tasks, event create, edit, RSVP and delete, the Mac menu bar extra, and live changes over SSE on both apps.

Status unknown, not checked: de-duplicating an event shared into both Google accounts, and a Nov 9 note that the server's `createEvent` hard-deletes a duplicate row when Google sync races it.

## Working in the repo

`AGENTS.md` at the repo root has the layout, commands and conventions. What it does not say:

**Checks**

- TypeScript, from the root: `pnpm build && pnpm typecheck && pnpm test`.
- Swift packages, inside `apple/FloridaCore` or `apple/FloridaKit` in an orb: `. ~/.local/share/swiftly/env.sh && swift build --build-tests && swift test`.
- The app targets (SwiftUI, AppKit, WidgetKit) only compile with Xcode: a Mac satellite, or CI after a push. A Linux build does not catch Darwin-only name clashes.

**Mac satellite, as used in the build thread**

- Image `macos-26`, synced path `apple`. The repo lands at `/Users/runner/workspace/repo`. `xcodegen` is installed; `rg` is not.
- After adding or removing a source file, run `xcodegen generate` in `apple`.
- Mac UI tests, in `apple`, after removing `mac-ui.xcresult`: `xcodebuild test -project Florida.xcodeproj -scheme Florida-macOS -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath build -resultBundlePath mac-ui.xcresult CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""`. Add `-only-testing:Florida-macOSUITests/SmokeTests/<testName>` for one test. It takes several minutes, so it was run in the background with output to a log file.
- Captures: `xcrun xcresulttool export attachments --path mac-ui.xcresult --output-path mac-screenshots`; `manifest.json` maps each exported file to a readable name such as `jump-light_0_<uuid>.png`.
- Both apps' UI tests launch with `-demoData YES -uiAppearance light|dark`. The demo data is `apple/iOS/Support/DemoData.swift` and is shared by both apps; ids look like `demo-task-keys`.

**CI and shipping**

- `ci.yml` runs on every push to `main` and on pull requests: scheduler and server, the Swift packages on Linux, and an Xcode build of the apps.
- `ios.yml` runs on changes under `apple/`; on `main` it also uploads to TestFlight.
- `macos.yml` runs on pushes to `main` that change `apple/`: the Mac UI smoke test, then a TestFlight upload.
- So a push to `main` that touches `apple/` ships two builds, about 20 minutes later. Apple allows about 20 uploads per app per day.
- There is no deploy workflow. The server is deployed by hand with `fly deploy` from the repo root; the release command runs the migrations and then the seed. `.agents/setup` installs `flyctl` and `neonctl`, which read `FLY_API_TOKEN` and `NEON_API_KEY` from the Amp project's secrets.
- Deploy the server before shipping an app build that needs a new route or field.

**Commits so far**

- Authored as `Amp <amp@ampcode.com>`, with the trailers `Co-authored-by: Swaraj Banerjee <swarajban@gmail.com>` and `Amp-Thread-ID: <thread URL>`.
- One commit per layer, in dependency order: scheduler, server, Swift packages, apps, then README and tests.
- The build thread worked under a note not to run `git checkout`, `git stash` or `git reset`. I only have that as one line from an earlier summary and do not know who set it.

## Things that will trip you up

- **`AGENTS.md` is partly out of date.** It says categories carry "the schedule whose hours apply" and are used instead of projects; since scheduling v2 a category carries an area, the routine decides hours, and projects exist. It names `placements` and `unscheduled` as the only stored derived data; the server now also stores optional placements, project time, routine occurrences and briefs.
- **The design doc is out of date above its "Scheduling v2" section.** Its data model, API list, milestones and progress log describe the state before Nov 9.
- **Mac keys.** `m` is Move and the month view is `⇧M`; `x` is Delete; `n` is Do now. `MacKeymap` must stay prefix-free: no binding may be the start of another. FloridaCore's `Keymap.default` is the shared base and `MacKeymap.macBindings` adds to and overrides it.
- **The Mac grid is one `Canvas`.** UI tests cannot read text in it; they assert through the task pane or an editor instead.
- **Older clients.** The server reads an omitted `area`, `context` or `projectId` as "keep the stored value", because shipped builds omit fields they do not know. Keep that when adding a field.
- **Both sides of the wire.** `FloridaCore/.../Models/Models.swift` mirrors `server/src/db/schema.ts` and the bodies in `server/src/app.ts` field for field. The local store is at migration v6 (`FloridaKit/.../Store/AppDatabase.swift`); the server is at Drizzle migration `0006`.
- **Swift names.** `TaskCategory` and `TaskItem`, never `Category`, `Label` or `Task`: they collide with Apple's own types, and only Xcode reports it.

## Older documents

All three are Amp artifacts, not files in this repo.

- [Florida — design](https://ampcode.com/artifacts/florida-design-e311c92e-0792-43c0-9fc7-c47d3b4d66b8): architecture and the "Decisions to veto" list. Current only in its "Scheduling v2" section.
- [Scheduling v2 proposal](https://ampcode.com/artifacts/florida-scheduling-v2-proposal-6d1de367-6e35-4581-a2b0-57b12579a604): the plan as decided on Nov 9, including his real weekly routine. Written before any of it was built.
- [Daily-driver review](https://ampcode.com/artifacts/florida-daily-driver-review-506b78fe-30f9-4465-af01-35aecec9fd90): the Nov 9 review of the apps as a daily driver, his ballot on 22 proposals, and the build log up to TestFlight build 181. Its "Later" list (out of office, availability sharing, scheduler knobs, account health, deep links, a Done view, a second time zone) is the main source of ideas he has already seen.
