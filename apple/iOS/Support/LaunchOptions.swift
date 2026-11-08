import Foundation

/// Launch arguments the CI screenshot run passes, as in
/// `xcrun simctl launch <udid> com.swarajban.florida -demoData YES -uiTab agenda`.
/// Both are read from the argument domain of `UserDefaults` and only in Debug builds; a Release
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
}
