import SwiftUI

/// Entry point of the iOS app. Owns the single `AppModel` for the process and hands it to every
/// view through the environment.
@main
struct FloridaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
