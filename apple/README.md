# Florida — Apple apps

The macOS app, the iOS app, and the iOS widget extension live here. The Xcode
project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen);
`Florida.xcodeproj` is a build artifact and is git-ignored (the root `.gitignore`
ignores `apple/*.xcodeproj`), so regenerate it after cloning or after editing
`project.yml`.

## Generate and open

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
| `d` `3` `w` `m` | day, 3-day, week, month view |
| `j` / `k` | move the selection through the focused panel |
| `⌘T`, `g t` / `g c` | toggle the task pane, focus tasks / calendar |
| `⌘K`, `/` or `⌘F` | command palette (quick add; type `>` for commands), search |
| `c`, `e` or `↩`, `x`, `space` | new task, edit, delete, complete |
| `p` / `⇧P`, `s`, `⌘1`–`⌘4` | pin / unpin to its slot (on an evening suggestion: do it tonight), snooze to tomorrow, priority ASAP…low |
| `⇧E`, `r y` / `r m` / `r n` | edit the selected event, RSVP yes / maybe / no |
| `g p`, `g b`, `y` | projects, today's brief and the weekly review, "Why here?" for the selected task |
| `o`, `⇧⌘C`, `⌘R`, `esc` | open in Google Calendar, copy link, sync now, cancel |

Quick add parses natural language locally (`QuickAddParser`): "infosec review
2h by fri high #work" sets duration, due date, priority, and category; the
palette shows the parsed chips before you press return. Double-clicking an
empty slot opens quick add prefilled with that time as a pinned start.

The scheduler's suggestions for an optional routine block (the evening) sit
on top of the task pane and as dotted blocks in the grid. They are not on the
plan: `p` or "Do tonight" pins the task to the suggested time, and a pinned
task's block moves at once, before the server answers. A new task from the
editor (`⇧N`) starts with a soft due date on the next weekday; a due date is a
day unless "Add a time" is on. The editor's Dates section holds Start (the task
is not scheduled before it) above Due, and a start moved to or past the due
date moves the due date to the day after. Categories are listed in one order
everywhere: Inbox, work, personal, then those without an area, by name within
each. Settings → Routine shows the weekly blocks tasks
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
then toggle which calendars to show. While open, the app listens to the
server's `/api/events` stream and also syncs every 60 s.

### iOS (`Florida-iOS`)

Three tabs. **Agenda**: a week strip over the day's all-day events, timed
events, and scheduled task blocks; swipe to change day, pull to refresh. An
event is a card filled in its calendar's color; a task block is the scheduler's
suggestion, so it has no fill, a dashed bar (solid once pinned) and an unticked
circle. The
evening's suggestions follow the day's plan ("Evening, if you're up for it"),
each with a "Do tonight" button that pins it; in the day grids they are dotted
blocks.
**Tasks**: sections per category, a quick-add field with the same parser and
chips as the Mac app, swipe to complete or delete, tap to edit. The editor
opens on Mark done, the title, then Start and Due in one Dates section; Due is
on for a new task from + (soft, the next weekday), both are whole days unless a
time is added from the row's menu, and a start moved to or past the due date
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

### Widgets (`FloridaWidgets`)

Three widgets, all reading the shared store directly and deep-linking into the
app (`florida://agenda`, `florida://tasks`):

- **Up Next** (small, medium, lock-screen rectangular): the next timed events
  and task blocks; its timeline has an entry at every start and end in the
  next six hours.
- **Today** (medium, large): what is left today, all-day first; refreshes
  hourly.
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
