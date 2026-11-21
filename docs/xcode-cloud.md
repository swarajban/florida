# Florida on Xcode Cloud

Use one iPhone 17 Pro Max simulator and one Mac destination. Each Test action already builds its app and extensions, so don't add a separate Build action. Leave archives and TestFlight to GitHub Actions. Compare actual compute minutes from the pilot against your monthly allowance before enabling an automatic trigger; test execution time doesn't include the build or simulator startup.

## Prepare your Mac

After this change lands on `main`, update your local clone. Use Xcode 27.1 or newer, confirm team `8G7N7547R6` under **Xcode → Settings → Accounts**, and install iOS platform support under **Settings → Components**.

```sh
git switch main && git pull --ff-only
brew install xcodegen # one time, if not installed
CI_PRIMARY_REPOSITORY_PATH="$PWD" apple/ci_scripts/ci_post_clone.sh
xcodebuild -project apple/Florida.xcodeproj -list
open apple/Florida.xcodeproj
```

The post-clone hook generates the project and shared schemes and copies `apple/Package.resolved` into the project workspace to pin GRDB to 7.12.0. Keep the generated project untracked.

## Create the workflow

1. Open the **Report navigator** (⌘9), select **Cloud → Get Started**, and choose the iOS app (`com.swarajban.florida`, team `8G7N7547R6`). Keep automatic signing.
2. Edit the workflow. Name it **Essential Checks** and select `apple/Florida.xcodeproj`. Use **Latest Release** of Xcode and a compatible macOS image. Set `DEVELOPMENT_TEAM` to `8G7N7547R6` (not a secret). Start with **Manual Start** only.
3. Add exactly these two **Test** actions. Mark both required to pass. Remove any Build, Archive, or post-actions.

   | Platform | Scheme | Test plan (Use Scheme Settings) | Destination |
   | --- | --- | --- | --- |
   | iOS | `Florida-iOS` | `FloridaEssentialiOS` | Uncheck Recommended iPhones; select only **iPhone 17 Pro Max** |
   | macOS | `Florida-macOS` | `FloridaEssentialMac` | **Mac** |

4. Choose **Grant Access** and authorize the Xcode Cloud GitHub App for **Only select repositories → `swarajban/florida`**. Return to Xcode and complete setup. No personal access token or App Store Connect API key is needed.

## Run one pilot, then enable PRs

1. Start a manual build on `main`. Your Mac can go offline once the build is queued.
2. Check the post-clone logs, both Test actions, and the GitHub check. Confirm each platform runs its unit tests and two UI smoke methods. The post-xcodebuild hook rejects zero passing tests and failures in a nominally successful test action.
3. After the pilot passes, edit **Essential Checks** in Xcode or **App Store Connect → Florida → Xcode Cloud → Workflows**. Add **Pull Request Changes** from any branch targeting `main`, restricted to changes in `apple/`, with **Auto-Cancel Builds** on. Leave **Branch Changes** off.
4. Flag that the workflow is live before changing the GitHub PR compile check. GitHub still builds and uploads both TestFlight apps on Apple-changing pushes to `main`.

## GitHub Actions fallback

```sh
gh workflow run ios.yml --ref <branch> -f essential_tests=true
```

This runs both scheme defaults without uploading. GitHub prefers iPhone 17 Pro Max, then iPhone 17 Pro, then another available Pro Max or iPhone. Full suites are manual only (`-f ui_only=true` without selectors); supply a selector alongside `ui_only=true` to run a subset of the full plan. The Linux suites still cover FloridaCore, FloridaKit, the scheduler, and the server.
