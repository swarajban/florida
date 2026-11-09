import AppKit
import FloridaKit
import SwiftUI

@main
struct FloridaMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    static let mainWindowID = "main"

    var body: some Scene {
        WindowGroup("Florida", id: Self.mainWindowID) {
            RootView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            AppCommands(model: appDelegate.model)
        }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }

        // Replaces a separate date / next-meeting menu bar app, so it is always there.
        MenuBarExtra {
            MenuBarAgendaView()
                .environment(appDelegate.model)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the model so it (and its change stream and periodic sync) lives as long as the app,
/// not as long as a window: ⌘W closes the window and the app keeps running; clicking the Dock
/// icon opens a new window on the same model.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Lazy so it is created on the main actor at first use rather than in the inherited
    /// `NSObject.init`, which is not main-actor isolated.
    private(set) lazy var model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// True lets SwiftUI do its default on a Dock click with no window open: open a new one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}
