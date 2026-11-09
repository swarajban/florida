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
| `iOS/` | iOS app target (`Florida-iOS`) |
| `macOS/` | macOS app target (`Florida-macOS`) |
| `Widgets/` | iOS WidgetKit extension (`FloridaWidgets`) |

XcodeGen writes `Info.plist` and `.entitlements` files into `iOS/`, `macOS/`,
and `Widgets/` on every generate; edit their contents in `project.yml`, not on
disk.

## Identifiers

- Bundle id prefix: `com.swarajban.florida` (`options.bundleIdPrefix` in
  `project.yml`). The app targets set explicit `PRODUCT_BUNDLE_IDENTIFIER`s:
  `com.swarajban.florida` (iOS), `com.swarajban.florida.widgets` (widgets), and
  `com.swarajban.florida.mac` (macOS).
- App group: `group.com.swarajban.florida`, declared in each target's
  entitlements in `project.yml` and mirrored by `Florida.appGroup` in
  `FloridaKit/Sources/FloridaKit/FloridaKit.swift`.

If you fork this for your own account, change the bundle id prefix, the three
`PRODUCT_BUNDLE_IDENTIFIER`s, the app group (in `project.yml` and
`FloridaKit.swift`), and register the app group under your team in the Apple
Developer portal; automatic signing handles the rest.

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
| `p` / `⇧P`, `s`, `⌘1`–`⌘4` | pin / unpin to its slot, snooze to tomorrow, priority ASAP…low |
| `o`, `⇧⌘C`, `⌘R`, `esc` | open in Google Calendar, copy link, sync now, cancel |

Quick add parses natural language locally (`QuickAddParser`): "infosec review
2h by fri high #work" sets duration, due date, priority, and category; the
palette shows the parsed chips before you press return. Double-clicking an
empty slot opens quick add prefilled with that time as a pinned start.

First run: Settings (`⌘,`) → server URL and bearer token (kept in the Keychain),
then toggle which calendars to show. While open, the app listens to the
server's `/api/events` stream and also syncs every 60 s.

### iOS (`Florida-iOS`)

Three tabs. **Agenda**: a week strip over the day's all-day events, timed
events, and scheduled task blocks; swipe to change day, pull to refresh.
**Tasks**: sections per category, a quick-add field with the same parser and
chips as the Mac app, swipe to complete or delete, tap to edit. **Settings**:
server URL and token, sync now, run the scheduler, refresh Google calendars,
and the connected accounts with their calendars. The app syncs on launch, when
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
- **Tasks** (small, medium): open tasks in scheduler order with the open count;
  late tasks in red.

## Building and shipping from GitHub Actions (no Mac needed)

Two workflows build the Apple code:

- `.github/workflows/ci.yml` (job **Apple apps**) builds `Florida-macOS` and
  runs the package tests on a macOS runner on every push and pull request.
- `.github/workflows/ios.yml` runs on changes under `apple/`. Its **build** job
  compiles `Florida-iOS` (with the widgets) for the simulator, then launches
  the app with `-demoData YES -uiTab <agenda|tasks|settings>` (plus
  `-uiSheet <event|aitask>` for the event detail and AI draft sheets) and uploads
  screenshots of each tab, light and dark, as the `screenshots` artifact. On
  pushes to `main`, or when started by hand (**Actions → iOS → Run workflow**),
  the **testflight** job also archives the app, signs it, and uploads it to
  TestFlight.

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

### Versions and signing

`MARKETING_VERSION` (`1.0`) and `CURRENT_PROJECT_VERSION` in `project.yml` feed
`CFBundleShortVersionString` and `CFBundleVersion` of every target. The
workflow overrides the build number with `run_number * 10 + run_attempt`, so
each upload is unique and both the app and the widget extension carry the same
one, as App Store Connect requires. Bump `MARKETING_VERSION` by hand when the
version should change.

The archive is built unsigned. The export step signs it with Apple's
cloud-managed distribution certificate through the API key, so no development
profile, registered device, or local certificate is needed. The app icon is
the single 1024×1024 image in `iOS/Assets.xcassets/AppIcon.appiconset`, which
App Store Connect requires for every upload.

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
