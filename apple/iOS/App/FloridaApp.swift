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
            RootView()
                .environment(model)
                .preferredColorScheme(FloridaStyle.captureColorScheme)
        }
    }
}
