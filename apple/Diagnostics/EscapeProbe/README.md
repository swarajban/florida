# Temporary Escape delivery diagnostic

This independent UIKit app has no SwiftUI, Florida packages, storage, network, signing
credentials or release jobs. `project.yml` is separate from `apple/project.yml`; normal
Florida targets do not include these sources. Delete this directory and
`.github/workflows/escape-probe.yml` after the investigation.

The single test focuses an empty `UITextView`, verifies no marked text, sends XCUI Tab
as a positive HID control (usage 43), then sends XCUI Escape (usage 41). It records
application/window press events and text-view `pressesBegan`, with phase, HID code and
modifier numbers only. It also observes application `sendAction` selectors and
passthrough `accessibilityPerformEscape` on the application, window, controller and
text view. These observations do not add a cancel handler or consume any event.
The trace contains no typed text or key characters.

For this raw phase, the text-view subclass returns an empty `keyCommands` array.
Its inherited `super.keyCommands` are inventoried after focus using action selector,
whether the input is Escape, modifier flags and priority. The active responder chain
is also inventoried with command counts and Escape selectors. Ancestor commands and
all superclass press/action/accessibility behavior remain unchanged. No explicit
Escape command is registered.

The test fails if the Tab control does not reach all three layers, or if the input
is not first responder/unmarked before Escape. **It does not fail if Escape is absent.**
`before-tab`, `after-tab`, `after-escape` and `escape-verdict` attachments, XCTest
output and the result bundle distinguish observed delivery from absence. Application
`sendAction` observation cannot detect actions invoked directly by UIKit; absence
there does not rule out every internal cancellation route.

Use the already-registered iOS workflow on the intended branch, once, with
`ui_only=true` and `escape_probe_only=true`. It calls the isolated reusable probe
workflow while disabling the normal build, full UI suites and every release job.
It selects the latest available iOS runtime and a non-Max Pro iPhone, using the same
selection as `apple/scripts/check.sh`, on `macos-26`. There are no push/PR triggers,
retries, release steps or TestFlight uploads. Only the `escape-probe` diagnostic
artifact is uploaded.

The reusable probe is not independently dispatchable. The existing iOS entry point
avoids registering a new default-branch workflow or merging a feature just to run it.

To run locally on a Mac with Xcode and XcodeGen, from this directory:

```sh
xcodegen generate
xcodebuild test -project EscapeProbe.xcodeproj -scheme EscapeProbe \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:EscapeProbeUITests/EscapeProbeTests/testEscapeDelivery \
  -derivedDataPath build/DerivedData -resultBundlePath build/diagnostic.xcresult \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

An absent Escape at application entry establishes a limit before this public dispatch
hook on that simulator/toolchain, not proof of a particular XCTest bug or of physical
keyboard behavior. Delivery here but not in QuickAdd points back to its hosting/routing
environment. A real physical-key check is still needed before claiming that user goal.
