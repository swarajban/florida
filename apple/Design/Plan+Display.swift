import FloridaKit
import Foundation

// How projects, day kinds and parallel work read on screen, shared by the iOS and Mac apps.

extension ProjectStatus {
    /// SF Symbol for the projects list and status pickers.
    var symbolName: String {
        switch self {
        case .active: "bolt.fill"
        case .thinking: "lightbulb"
        case .onHold: "pause.circle"
        case .done: "checkmark.circle"
        }
    }

    /// What the projects list says under the status heading.
    var footnote: String {
        switch self {
        case .active: "Scheduled: its tasks are on the plan."
        case .thinking: "Ideas you are still weighing. Nothing is scheduled."
        case .onHold: "Paused. Nothing is scheduled until it is active again."
        case .done: "Finished."
        }
    }
}

extension DayKind {
    /// SF Symbol for the day chip and the day commands.
    var symbolName: String {
        switch self {
        case .home: "house"
        case .office: "building.2"
        case .off: "moon.zzz"
        }
    }

    /// "a home day", "an office day", "a day off": for "Today is …".
    var sentenceLabel: String {
        switch self {
        case .home: "a home day"
        case .office: "an office day"
        case .off: "a day off"
        }
    }
}

extension TaskAttention {
    var displayName: String {
        switch self {
        case .full: "Full attention"
        case .shared: "Can run in parallel"
        }
    }
}

/// Words for the plan's v2 parts, so both apps say the same thing.
enum PlanText {
    /// SF Symbol marking work that runs beside other work.
    static let parallelSymbol = "square.split.2x1"
    /// SF Symbol for a commitment the routine placed (the gym).
    static let commitmentSymbol = "figure.strengthtraining.traditional"
    /// SF Symbol for time held for a project without a task.
    static let projectSymbol = "square.stack.3d.up"

    /// "Alongside Infosec audit and Florida": what a block that shares its time says.
    static func alongside(_ titles: [String]) -> String {
        "Alongside \(ListFormatter.localizedString(byJoining: titles))"
    }

    /// "Project time": the subtitle of time the scheduler holds for a project.
    static let projectTime = "Project time"

    /// "Gym: no free slot for the extra session this week": what the plan says when a commitment
    /// (the gym) could not be placed on its default day or its fallback.
    static func missed(_ names: [String]) -> String {
        "\(ListFormatter.localizedString(byJoining: names)): no free slot for the extra session this week"
    }

    /// "1h 30m free": the day's open computer time, or nil when there is none to report.
    static func free(_ minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        let hours = minutes / 60
        let rest = minutes % 60
        let amount = hours == 0 ? "\(rest)m" : rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        return "\(amount) free"
    }

    /// What the project editors say under the Parallel switch.
    static let parallelFootnote = "A parallel project's tasks can share an hour with up to two other parallel projects."

    /// What the project editors say under weekly time.
    static let weeklyFootnote = "The scheduler holds this much time for the project each week, even without tasks."
}
