# Florida — Apple apps

The macOS app, the iOS app, and the iOS widget extension live here. The Xcode
project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen);
`Florida.xcodeproj` is a build artifact and is git-ignored (the root `.gitignore`
ignores `apple/*.xcodeproj`), so regenerate it after cloning or after editing
`project.yml`.

## Generate and open

Use a Mac with Xcode for the local app build and UI-test loop before opening a
pull request; Linux package tests cannot catch Darwin-only compile errors.

```sh
brew install xcodegen
cd apple
DEVELOPMENT_TEAM=<your Apple team id> xcodegen generate
open Florida.xcodeproj
```

`DEVELOPMENT_TEAM` is substituted into the project's build settings when the
project is generated, so re-run `xcodegen generate` with it set whenever you
regenerate. In Xcode, pick the **Florida-iOS** or **Florida-macOS** scheme and
run. The **FloridaWidgets** extension is embedded in the iOS app and is built
with it.

## Local Mac verification

On a connected Mac (including alnilam's `/Users/swaraj/florida`), use an isolated
worktree for your branch, not another agent's checkout. Install XcodeGen with
`brew install xcodegen`, select Xcode with `xcode-select`, and install an iPhone
simulator runtime in Xcode. From the repository root:

```sh
bash apple/scripts/check.sh generate
bash apple/scripts/check.sh build
bash apple/scripts/check.sh ios
bash apple/scripts/check.sh macos

# A single test (the same options work for either suite):
bash apple/scripts/check.sh ios -only-testing:Florida-iOSUITests/SmokeTests/testUnifiedTaskCapture
bash apple/scripts/check.sh macos -only-testing:Florida-macOSUITests/SmokeTests/testRecurringEventCreation
```

`build` generates the project with an empty development team and runs
`xcodebuild build-for-testing` for **both** schemes. This compiles the iOS app,
embedded widgets, Mac app and test runners without distribution credentials.
The Mac products are ad-hoc signed so the UI runner can launch. `ios` and `macos`
regenerate and use `xcodebuild test`, incrementally reusing `apple/build/ios`
and `apple/build/macos`. They run serially within each suite; the tests already
cover light and dark appearances. `ios` chooses a Pro iPhone on the newest
installed iOS runtime; set `UDID` to use a particular available simulator.

To reproduce CI's reuse of compiled products, run `build`, then
`TEST_WITHOUT_BUILDING=1 bash apple/scripts/check.sh ios` (or `macos`). Each run
writes a fresh result bundle under `apple/build/results/`. Export screenshots
with `xcrun xcresulttool export attachments --path <result.xcresult> --output-path <screenshots>`.
Local runs do not retry by default; `RETRY_FAILED_TESTS=1` enables one retry of
failed tests without changing assertions. A passing retry is not a flake fix.

### Pull request and release checks

On **every PR push**, `ci.yml` runs TypeScript and both Linux Swift package
suites. If the PR changes `apple/**` or an Apple CI/release workflow, one
compile-only Xcode job builds both apps, the widgets and UI test bundles. It
caches SwiftPM and derived data by toolchain/architecture, but runs no UI tests.
Superseded PR runs are cancelled. Branch pushes do not start a duplicate iPhone
workflow, and unrelated PRs use no macOS runners.

**Once before merge**, when the head is otherwise ready, request both UI suites:

```sh
gh workflow run ios.yml --ref <PR-branch> -f ui_only=true
gh run list --workflow ios.yml --branch <PR-branch> --event workflow_dispatch
```

This explicit dispatch uses the existing iOS workflow's `ui_only` mode: it never
starts a release or reads release secrets. It runs against the branch head, so
its **On-demand Apple UI** checks appear on that commit in the PR. Unlike a
sticky label, it does not rerun on each subsequent push. Confirm the run's
`headSha` matches the PR's current `headRefOid` (`gh run view <run-id> --json headSha`
and `gh pr view <PR> --json headRefOid`) and require all UI checks to pass before
merge. A later push invalidates that result: cancel any stale run with
`gh run cancel <run-id>` and request a new run when ready. A new UI request on
the same branch automatically cancels a superseded request. UI-only requests
have a separate concurrency group, so they cannot cancel or replace a queued
release, even if dispatched on main.

The on-demand run uses the same cached build recipe as the compile gate, builds both
schemes once and runs Darwin package tests, then uploads the compiled products.
Three independent jobs use `test-without-building`: the full Mac suite, iPhone
capture/plan tests, and all remaining iPhone tests plus widget tests. The capture
shard selects three long tests; the other excludes only those three, so new
tests automatically join the gate. Each shard is serial to avoid desktop and
simulator interaction races; failure in one does not cancel the others.

PR and release UI tests get at most one native XCTest retry of failed tests
only, without weakening assertions. First failures remain in the raw log and
xcresult and are listed in the run summary even if the retry passes. Results
and logs are artifacts for seven days; a passing retry is not a flake fix.

Main's release workflows remain separate. After an Apple-changing merge,
`ios.yml` runs the complete iPhone/widget suite and `macos.yml` runs the full
Mac suite, **without gating TestFlight for now, by Swaraj's choice**. Independent
archive/sign/upload jobs compile the apps and can upload before UI tests finish
or even when they fail. A persistent UI failure is still a failed check and is
listed in that job's run summary; it is not hidden with `continue-on-error`.

The single checked-in switch is `APPLE_UI_GATE: 'false'` in
`.github/workflows/apple-release-policy.yml`. Change that value to `'true'` to
make both upload paths depend on successful full UI suites again. With it off,
uploads depend only on the small Linux policy job, never on a UI job. Release
serialization applies only to the upload job, so an earlier run's slow UI suite
cannot hold up the next upload. Active uploads are never cancelled by later runs.

Ordinary manual iOS dispatches still release (`ui_only` defaults to false).
Uploads do not use PR test artifacts and retain
`run_number * 10 + run_attempt` build numbering. A change under `apple/`, even a
README or script, still triggers both releases on main.

## Layout

| Path | What it is |
| --- | --- |
| `project.yml` | XcodeGen spec: targets, Info.plist and entitlements contents, build settings |
| `FloridaCore/` | Local Swift package, no dependencies: models, quick-add parser, keyboard engine, calendar layout math. Builds and tests on Linux |
| `FloridaKit/` | Local Swift package shared by all three targets: local SQLite store (GRDB), sync client, token store. Re-exports FloridaCore |
| `Design/` | Shared app identity, semantic light/dark surfaces, vector masters and asset generator; see its README |
| `iOS/` | iOS app target (`Florida-iOS`) |
| `macOS/` | macOS app target (`Florida-macOS`) |
| `macOSUITests/` | Native keyboard smoke test and light/dark screenshots, using the iOS demo fixture |
| `Widgets/` | iOS WidgetKit extension (`FloridaWidgets`) |

XcodeGen writes `Info.plist` and `.entitlements` files into `iOS/`, `macOS/`,
and `Widgets/` on every generate; edit their contents in `project.yml`, not on
disk.

## Identifiers

- Bundle id prefix: `com.swarajban.florida` (`options.bundleIdPrefix` in
  `project.yml`). The app targets set explicit `PRODUCT_BUNDLE_IDENTIFIER`s:
  `com.swarajban.florida` (both iOS and native macOS, sharing the Florida Tasks
  App Store Connect record) and `com.swarajban.florida.widgets` (widgets).
- App group: `group.com.swarajban.florida`, declared in each target's
  entitlements in `project.yml` and mirrored by `Florida.appGroup` in
  `FloridaKit/Sources/FloridaKit/FloridaKit.swift`.

If you fork this for your own account, change the bundle id prefix, the three
`PRODUCT_BUNDLE_IDENTIFIER`s (keep iOS and macOS identical), the app group (in
`project.yml` and `FloridaKit.swift`), and register the app group under your
team in the Apple Developer portal; automatic signing handles the rest.

## The apps

All three targets read only the local SQLite store in the App Group container
and never wait on the network to render. The apps write locally first, queue
the change, and sync it; the widgets only read.

### macOS (`Florida-macOS`)

One window: the calendar grid (day, 3-day, week, or month) with a task pane
grouped by category, and a status bar with sync state. Every action has a key;
press `?` for the full list (it is `Keymap.default` in FloridaCore). The main
ones:

| Keys | Action |
| --- | --- |
| `h` / `l`, `⇧H` / `⇧L`, `t`, `g d` | previous/next day, previous/next week, today, go to date |
| `d` `3` `w` `⇧M` | day, 3-day, week, month view |
| `j` / `k` | move the selection through the focused panel |
| `f` | jump: label every task and event on screen, then type a label to open it |
| `⌘T`, `g t` / `g c` | toggle the task pane, focus tasks / calendar |
| `⌘K`, `/` or `⌘F` | command palette (quick add; type `>` for commands), search |
| `c`, `e` or `↩`, `x`, `space` | new task, edit, delete, complete |
| `z` or `u`, `g n` | undo the last change, scroll to now |
| `p` / `⇧P`, `s`, `⌘1`–`⌘4` | pin / unpin to its slot (on an evening suggestion: do it tonight), snooze to tomorrow, priority ASAP…low |
| `⇧E`, `r y` / `r m` / `r n`, `v` | edit the selected event, RSVP yes / maybe / no, join its video call |
| `g r` | open the selected event's resources in a searchable picker; arrows select, Return opens |
| `g p`, `g b`, `y` | projects, today's brief and the weekly review, "Why here?" for the selected task |
| `o`, `⇧⌘C`, `⌘R`, `esc` | open in Google Calendar, copy link, sync now, cancel |

Quick add parses natural language locally (`QuickAddParser`): "infosec review
2h by fri high #work" sets duration, due date, priority, and category; the
palette shows the parsed chips before you press return. Double-clicking an
empty slot opens quick add prefilled with that time as a pinned start.

An opened task or event shows the key for each control beside it. The task
editor opens with no field focused, so its keys (`TaskEditorKey` in
FloridaCore) act at once: `space` marks the task done; `s`, `d` and `i` open
Start, Due and Pinned start. `c` opens Category, `j` Project, `o` Context,
`p` Priority, `a` Attention and `h` the soft/hard Deadline choice. Clicking a
value opens the same anchored selector. Its search field is focused immediately;
typing ranks case-insensitive prefixes before substring and fuzzy matches.
Use arrows or `⌃N`/`⌃P`, then Return to choose. The current value starts
highlighted. Escape cancels without changing the value and leaves no field
focused, so the next editor key works. `⇧P` opens the selector too instead of
stepping; `⌘1`–`⌘4` still set priority directly. `z` does nothing in the editor.
New tasks also open unfocused; `t` focuses Title and `n` Notes.

Date selectors preview words such as `tomorrow`, `fri`, `nov 20`, `in 2 weeks`
and `next mon 3pm` as you type; `none` clears an optional date. Arrows move the
highlighted day in the compact month grid and Return picks it. Quick choices
are Today, Tomorrow, This weekend, Next week and No date. Tab focuses the grid,
where single keys `1`–`5` pick those choices without interfering with dates
typed as numbers. “Add a time” remains optional, and typing a clock time enables
it. Category selectors offer “Create ‘name’” when nothing matches; creation
and all choices are local-first, with no network round trip. The same selectors
serve event calendars and repeat rules, project status/category/weekly time,
and category areas. Direct two-way toggles, the brief's two tabs and the event
popover's Yes/Maybe/No RSVP buttons retain their faster direct controls and keys.

One click in the task pane selects the row with a visible outline and fill
and immediately opens its editor. The done circle still completes on one click
without opening the editor; after closing it, task keys act on that selection.
One click selects a calendar block and a double-click opens it.
Drag a timed event to move it: it snaps to 15 minutes,
keeps its length, and can cross day columns; an event with guests asks first,
because Google emails them. An event that repeats asks whether this one moves
or all of them. All Events is offered only for a drop on the event's own day:
the series takes the new time of day and every instance keeps its day
(`moveEventSeries` in FloridaKit shifts the stored instances at once and queues
one write with `scope: "series"`, which the server needs to move the series on
Google). Tasks do not drag, because the scheduler places them.

Event details show a compact resource shelf under Join, including when opened
through a jump label. Links are extracted locally from the description and
location: Google Docs, Sheets and Slides, Notion, Figma, GitHub, Linear, meeting
links and other websites show readable titles and provider labels. Duplicate
URLs appear once, and the primary meeting link stays in Join. Click a resource
to open it in your browser or its app, or type its digit keycap while the
popover is open. Resource labels are prefix-free and become two digits for
larger shelves; they don't change the calendar's existing view keys. The first
100 resources have direct digit labels. Further links show `g r` instead and
remain available through the searchable picker.
Run **Open event resources** in the
command palette (`g r` also works while the event popover is open). The picker
can filter by title and reaches every resource without numbered-link limits.

The scheduler's suggestions for an optional routine block (the evening) sit
on top of the task pane and as dotted blocks in the grid. They are not on the
plan: `p` or "Do tonight" pins the task to the suggested time, and a pinned
task's block moves at once, before the server answers. A new task from the
editor (`⇧N`) starts with a soft due date on the next weekday; a due date is a
day unless "Add a time" is on. The editor's Dates section holds Start (the task
is not scheduled before it) above Due, and a start moved to or past the due
date moves the due date to the day after. Categories are listed in one order
everywhere: Inbox, work, personal, then those without an area, by name within
each, ignoring case. Category search and the move palette preserve that order
even while filtering, instead of reordering categories by relevance. A category
with no Area sorts last; set Work or Personal directly in Settings → Categories.
Settings → Routine shows the weekly blocks tasks
are scheduled in; a task's context decides which blocks it may use, and a
category's Area (Work or Personal) puts personal tasks first in the evening's
suggestions.

A task can belong to a project (`g p`: status, next step, hours a week, and
whether its work may run in parallel). Up to three tasks of different parallel
projects share an hour; the grid draws them side by side in lane order, and a
task's Attention field overrides its project. Hatched blocks are the plan's own
entries, not tasks: the gym from the routine, and project time that fills a
project's weekly hours. A day's kind (home, office, off) comes from the routine;
right-click a day header, or run "Set Day" from the palette, to change one day.
`g b` shows the brief the server's model writes each morning and the weekly
review, and `y` asks it why the selected task sits where it does. All three need
`ANTHROPIC_API_KEY` on the server and say so plainly without it.

First run: Settings (`⌘,`) → server URL and bearer token (kept in the Keychain),
then choose each calendar's independent **Show calendar** and **Blocks scheduling**
switches. Both apps update these locally at once: hidden calendars can still
block tasks, and visible calendars can be informational only. While open, the app listens to the
server's `/api/events` stream and also syncs every 60 s.

Ordinary all-day events do not block tasks by default, regardless of Google's busy/free
setting. In either app's all-day event details, **Blocks my day** offers **Automatic**,
**Blocks**, and **Does not block**, and shows the effective state. Automatic blocks
only out-of-office events; an explicit choice overrides that, including for OOO.
The choice applies to this occurrence only, even on a read-only Google calendar,
and is saved locally and queued for Florida sync without editing Google. On Mac,
`r b` cycles the three choices in the popover or on the selected all-day event;
"Cycle day blocking" is also in the command palette. The calendar's
**Blocks scheduling** switch remains the outer control.

### iOS (`Florida-iOS`)

Three tabs. **Agenda**: a week strip over the day's all-day events, timed
events, and scheduled task blocks; swipe to change day, pull to refresh. An
event is a card filled in its calendar's color; a task block is the scheduler's
suggestion, so it has no fill, a dashed bar (solid once pinned) and an unticked
circle. The
evening's suggestions follow the day's plan ("Evening, if you're up for it"),
each with a "Do tonight" button that pins it; in the day grids they are dotted
blocks.
**Tasks**: sections per category, swipe to complete or delete, tap to edit.
Quick add, both tabs' add-task buttons, and the widget shortcut open one focused
text composer. It uses the same local parser as the Mac, previews the title and
dates, and offers category matches for `#` hints. Ambiguous prefixes require a
choice. Categorized tasks skip Inbox; unfiled tasks stay there until you choose
a category or accept a suggested one. Closing capture keeps its draft for the
current app session; saving locally clears it. **Details** opens the full editor
with the parsed fields; **Parse with AI** remains optional and requires review.
New tasks default to 30 minutes with no deadline unless one is typed. The editor
opens on Mark done, the title, then Start and Due in one Dates section; dates are
whole days unless a time is added from the row's menu, and a start moved to or past the due date
moves the due date to the day after. **Settings**:
server URL and token, sync now, run the scheduler, refresh Google calendars,
and the connected accounts with their calendars. Projects, parallel lanes, the
hatched gym and project-time blocks, day kinds and the briefs work as on the
Mac: Projects opens from the Tasks tab, the day's kind is the menu beside the
date in Agenda, today's brief is the card at the top of Agenda (the weekly
review opens from it), and "Why here?" is in the task editor under Project and
Attention. A task row shows its context. The app syncs on launch, when
it returns to the foreground, and every two minutes while active; after each
sync it reloads the widget timelines.

The iPhone event detail has the same **Resources** list below Join. Tap a row to
open its URL in your browser or the linked app; extraction needs no network.
The light/dark UI tests cover the shelf, duplicate/Join exclusion, and opening
resources; Mac tests also cover jump labels, `g r`, and the command palette.
Debug demo runs can pass `-uiRecordResourceOpens YES` to record resource actions
without opening a browser. The flag is ignored outside demo data and in Release.

Both event editors offer daily, weekly, monthly and yearly repeats when creating an
event, with an interval and an optional occurrence count. The rule uses the app's
calendar time zone so timed repeats keep their wall-clock time through DST. Save
is local and immediate; Google expands the series on sync. Later edits and deletes
affect one occurrence only; use Google Calendar to change the whole series.

### Widgets (`FloridaWidgets`)

Three widgets, all reading the shared store directly and deep-linking into the
app (`florida://agenda`, `florida://tasks`, `florida://tasks/new`):

- **Today's Agenda** (small, medium, lock-screen rectangular; replaces Up Next
  in place): compact rows for today's remaining events and scheduled tasks,
  all-day first, with today's date always in the Home Screen header. The lock
  screen shows the next timed item today.
- **Today** (medium, large): the same agenda with more room. Both agenda widgets
  update at start/end boundaries, clear yesterday at midnight, and request a
  store refresh every 30 minutes. Medium/large layouts have a **+** shortcut to
  the same quick-add composer as the app; the small widget opens Agenda because it has one tap target.
- **Tasks** (small, medium): open tasks in scheduler order with the open count
  and each task's category color; late tasks in red.

## Building and shipping from GitHub Actions (no Mac needed)

Three workflows build the Apple code:

- `.github/workflows/ci.yml` (job **Apple apps**) builds `Florida-macOS` and
  runs the package tests on a macOS runner on every push and pull request.
- `.github/workflows/ios.yml` runs on changes under `apple/`. Its **build** job
  compiles `Florida-iOS` (with the widgets) for the simulator, then launches
  the app with `-demoData YES -uiTab <agenda|tasks|settings>` (plus
  `-uiSheet <event|aitask|daypicker>` for the event detail, AI draft and month
  grid sheets, and `-uiAgendaMode <list|day|threeDays>` for the Agenda layout)
  and uploads
  screenshots of each tab, light and dark, as the `screenshots` artifact. On
  pushes to `main`, or when started by hand (**Actions → iOS → Run workflow**),
  the **testflight** job also archives the app, signs it, and uploads it to
  TestFlight.
- `.github/workflows/macos.yml` (**macOS TestFlight**) runs on pushes to `main`
  that change `apple/` or that workflow, and can be started by hand on `main`.
  It runs the native macOS UI smoke test, archives a Release build for Apple
  silicon and Intel, preserves its entitlements, then cloud-signs and uploads
  it to TestFlight using the same API-key secrets as iOS. It waits up to 20
  minutes for Apple's processing and reports the internal testing state in
  the run summary. Branches and pull requests never upload. A running upload
  is not cancelled by a newer push.

The demo launch arguments are Debug-only (`iOS/Support/LaunchOptions.swift`):
`-demoData YES` swaps the shared store for an in-memory one seeded from
`iOS/Support/DemoData.swift` and skips the server setup, so screenshots never
contain personal data and never reach a server. They work the same way from
Xcode's scheme editor (Run → Arguments).

On iPhone, add `-demoNow 2026-11-12T00:10:00Z` to freeze the demo calendar's
clock: its selected day, Today, seed data, now line and initial hour position
all use that instant. It is ignored without `-demoData YES` and in Release
builds. Omitting it keeps the real clock. The grid UI tests cover midnight,
late evening and real-clock launches, and verify each drag advances the task
by exactly 30 minutes without moving the viewport.

### One-time TestFlight setup

1. **Apple Developer Program:** a paid membership.
2. **Register the identifiers** at
   [developer.apple.com → Identifiers](https://developer.apple.com/account/resources/identifiers/list):
   an **App Group** `group.com.swarajban.florida`, then two **App IDs**,
   `com.swarajban.florida` (capabilities: App Groups with that group, Push
   Notifications) and `com.swarajban.florida.widgets` (App Groups). Xcode's
   cloud signing (`-allowProvisioningUpdates`) can usually create and update
   these itself; registering them first just removes one failure mode.
3. **Create the app record:** [App Store Connect → Apps](https://appstoreconnect.apple.com/apps)
   → **+ → New App**, iOS, any free name, bundle ID `com.swarajban.florida`,
   any SKU. The widget extension needs no record of its own.
4. **Create an API key:** [Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api)
   → **Team Keys** → generate a key with the **Admin** role (cloud signing
   creates certificates and profiles, which needs Admin). Download the `.p8`
   (only possible once) and note the **Key ID** and **Issuer ID**.
5. **Add repository secrets** (GitHub → Settings → Secrets and variables →
   Actions):

   | Secret | Value |
   | --- | --- |
   | `APP_STORE_CONNECT_KEY_ID` | Key ID from step 4: 10 characters, the part between `AuthKey_` and `.p8` in the file name |
   | `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from step 4 (a UUID) |
   | `APP_STORE_CONNECT_KEY_P8` | Full contents of the `.p8` file, `BEGIN/END PRIVATE KEY` lines included (base64 also accepted) |
   | `APPLE_TEAM_ID` | Optional. Defaults to `8G7N7547R6` in `ios.yml`; set it if the app should ship under another team |

6. **Run the workflow** (**Actions → iOS → Run workflow**). The workflow checks
   the key against the App Store Connect API before archiving, so credential
   problems show Apple's own error. After the upload, the build takes 5–15
   minutes to process.
7. **Install it:** in App Store Connect open the app → **TestFlight → Internal
   Testing**, create a group and add yourself, then accept the invite in the
   TestFlight app. Internal builds skip Beta App Review, and
   `ITSAppUsesNonExemptEncryption` is already `false` in `project.yml`, so
   there is no export-compliance prompt. Every push to `main` that touches
   `apple/` ships a new build; builds stay installable for 90 days.

### macOS TestFlight setup

Reuse the existing **Florida Tasks** App Store Connect record, developer
membership, Admin-role team API key, and repository secrets. Both native app
targets use `com.swarajban.florida`; no new app record, SKU, API key, or local
Xcode build is needed. The Mac build is the native `Florida-macOS` target,
not the iPhone app running on Apple silicon.

1. In [App Store Connect → Apps](https://appstoreconnect.apple.com/apps),
   open **Florida Tasks → Distribution**, click **Add Platform** in the
   sidebar, select **macOS**, and click **Add**. This keeps the existing app
   name, SKU, and bundle ID. See [Apple's Add platforms instructions](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms).
2. Reuse the existing App ID `com.swarajban.florida` and its **App Groups**
   assignment to `group.com.swarajban.florida`. Do not register a new `.mac`
   identifier. Automatic signing creates the macOS distribution profile.
3. Once the workflow is on `main`, open **GitHub → Actions → macOS TestFlight
   → Run workflow** and select `main`. The job checks that the app record is
   accessible before building. Automatic signing manages the distribution
   provisioning profile required by macOS TestFlight.
4. After Apple processes the upload, open **Florida Tasks → TestFlight** and
   select the **macOS** builds. Make the build available to your internal
   testing group and enable **automatic distribution** for future builds.
   The shared export options restrict builds to internal testers; no external
   Beta App Review is needed.
5. Install [TestFlight for Mac](https://apps.apple.com/app/testflight/id899247664),
   accept the invitation, and install Florida. Enable automatic updates in
   TestFlight. Florida requires **macOS 15 or later**.

Future qualifying pushes to `main` upload a new build without a local checkout
or Xcode. Builds expire after 90 days. Older locally built Mac copies used
`com.swarajban.florida.mac`. Before switching, sync any pending edits and quit
the old copy. The shared App Group stays the same, but the new bundle identity
can change private preferences, fallback storage, and Keychain access; you may
need to configure the server and token again and let it pull your data. No
automatic migration from the old app's private container is performed.
The workflow verifies the archive's entitlements before export and checks
Apple's processing result after upload. A real TestFlight installation is
still needed to confirm the final distribution build. If processing times
out, check the existing build in App Store Connect before rerunning the job;
an upload may have succeeded even when processing has not finished.

### Versions and signing

`MARKETING_VERSION` (`1.0`) and `CURRENT_PROJECT_VERSION` in `project.yml` feed
`CFBundleShortVersionString` and `CFBundleVersion` of every target. The
workflow overrides the build number with `run_number * 10 + run_attempt`, so
each upload is unique and both the app and the widget extension carry the same
one, as App Store Connect requires. Bump `MARKETING_VERSION` by hand when the
version should change.

The archive is built unsigned. The export step signs it with Apple's
cloud-managed distribution certificate through the API key, so no development
profile, registered device, or local certificate is needed. One catch: the
export keeps only the entitlements it finds in an existing code signature, and
an unsigned bundle comes out with the profile's defaults, without App Groups,
so the widgets see no shared store. The workflow therefore ad-hoc signs the
widget extension and the app inside the archive with the `.entitlements` files
XcodeGen wrote (`codesign --sign -`), checks that the App Group is in each
signature, and after the upload checks the export's `DistributionSummary.plist`
the same way. The app icon is the single 1024×1024 image in
`iOS/Assets.xcassets/AppIcon.appiconset`, which App Store Connect requires for
every upload.

## FloridaCore and FloridaKit

`FloridaCore` (`FloridaCore/Package.swift`) holds everything that is pure
logic: the models that mirror the server's JSON, the quick-add parser, the
keyboard-shortcut engine, and the day-grid layout math. It has no dependencies
and no I/O, so it builds and tests anywhere Swift runs.

`FloridaKit` (`FloridaKit/Package.swift`) is what the iOS app, the macOS app,
and the widgets import. It depends on `FloridaCore` (re-exported, so one
`import FloridaKit` is enough) and on
[GRDB.swift](https://github.com/groue/GRDB.swift) for the local SQLite store
in the App Group container, plus the sync client that talks to the server.

Both packages test with `swift test` from their directory (or via Xcode).
