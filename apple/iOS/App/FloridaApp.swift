import SwiftUI
import UIKit

/// Entry point of the iOS app. Owns the single `AppModel` for the process and hands it to every
/// view through the environment.
@main
struct FloridaApp: App {
    @State private var model = AppModel()

    init() {
        UIDatePicker.appearance().minuteInterval = 15
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if LaunchOptions.demoData && UserDefaults.standard.bool(forKey: "uiShareCapture") {
                ShareCaptureTestHost()
            } else {
                root
            }
            #else
            root
            #endif
        }
    }

    private var root: some View {
        RootView()
            .environment(model)
            .preferredColorScheme(FloridaStyle.captureColorScheme)
    }
}
