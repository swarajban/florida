import FloridaKit
import Foundation

/// The small delights of the agenda and widgets, each one a switch in Settings (all on by
/// default). Stored in the App Group defaults so the widget extension reads the same values;
/// `Widgets/Support/WidgetSupport.swift` repeats the one key it needs.
enum JoySetting: String, CaseIterable, Identifiable {
    case blockProgress = "joy.blockProgress"
    case freeGaps = "joy.freeGaps"
    case ghosts = "joy.ghosts"
    case dayCleared = "joy.dayCleared"
    case joinCountdownWidget = "joy.joinCountdownWidget"
    case widgetReloadOnWrite = "joy.widgetReloadOnWrite"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blockProgress: "Progress on the current task"
        case .freeGaps: "Free time between items"
        case .ghosts: "Keep finished blocks for the day"
        case .dayCleared: "“Day cleared”"
        case .joinCountdownWidget: "Join countdown on the Lock Screen"
        case .widgetReloadOnWrite: "Refresh widgets on every change"
        }
    }

    var detail: String {
        switch self {
        case .blockProgress: "The task block in progress fills as time passes and says how long is left."
        case .freeGaps: "Gaps of 15 minutes or more show how much time is free; tap one to pin a task that fits."
        case .ghosts: "Blocks you finish stay on today's agenda, struck through."
        case .dayCleared: "Today's header celebrates when its last task is done."
        case .joinCountdownWidget: "The Up Next Lock Screen widget counts down to a meeting from two minutes out."
        case .widgetReloadOnWrite: "Widgets update after each local change, not only after a sync."
        }
    }

    var isOn: Bool {
        UserDefaults.florida.object(forKey: rawValue) as? Bool ?? true
    }
}

extension UserDefaults {
    /// The App Group's defaults, shared with the widget extension.
    static var florida: UserDefaults {
        UserDefaults(suiteName: Florida.appGroup) ?? .standard
    }
}
