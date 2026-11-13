import Foundation

/// Launch arguments the CI screenshot run passes, as in
/// `xcrun simctl launch <udid> com.swarajban.florida -demoData YES -uiTab agenda -uiSheet event`.
/// All are read from the argument domain of `UserDefaults` and only in Debug builds; a Release
/// build ignores them.
enum LaunchOptions {
    static var recordSourceOpens: Bool {
        #if DEBUG
        return demoData && UserDefaults.standard.bool(forKey: "uiRecordSourceOpens")
        #else
        return false
        #endif
    }

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
    /// review's detail on the Agenda tab), `daypicker` (the month grid over the Agenda tab),
    /// `aitask` (an AI-parsed task under review on Tasks), `projects` (the Projects list on Tasks)
    /// or `project` (the editor on its first active project).
    static var initialSheet: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "uiSheet")
        #else
        return nil
        #endif
    }

    /// The Agenda layout to start in (`list`, `day` or `threeDays`), overriding the saved choice.
    static var initialAgendaMode: AgendaMode? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "uiAgendaMode").flatMap(AgendaMode.init(rawValue:))
        #else
        return nil
        #endif
    }
}
