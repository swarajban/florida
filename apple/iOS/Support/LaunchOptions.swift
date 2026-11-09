import Foundation
import SwiftUI

/// Launch arguments the CI screenshot run passes, as in
/// `xcrun simctl launch <udid> com.swarajban.florida -demoData YES -uiTab agenda -uiSheet event`.
/// All are read from the argument domain of `UserDefaults` and only in Debug builds; a Release
/// build ignores them.
enum LaunchOptions {
    /// Use a fresh in-memory store seeded with `DemoData` instead of the shared store, and skip
    /// the server setup prompts.
    static var demoData: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "demoData")
        #else
        return false
        #endif
    }

    /// The tab to show at launch (`agenda`, `tasks`, or `settings`).
    static var initialTab: AppTab? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "uiTab").flatMap(AppTab.init(rawValue:))
        #else
        return nil
        #endif
    }

    /// A sheet to open over the initial tab once the demo data is loaded: `event` (the design
    /// review's detail on the Agenda tab) or `aitask` (an AI-parsed task under review on Tasks).
    static var initialSheet: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "uiSheet")
        #else
        return nil
        #endif
    }

    /// Deterministic UI-test appearance; normal launches and Release builds follow the device.
    static var colorScheme: ColorScheme? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "uiAppearance") {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
        #else
        return nil
        #endif
    }
}
