import Foundation

/// Every action the keyboard engine and the command palette can trigger.
public enum AppCommand: String, Hashable, Sendable, CaseIterable {
    // navigation
    case nextDay, previousDay, nextWeek, previousWeek, today, goToDate
    case viewDay, viewWeek, viewThreeDays, viewMonth
    case focusNext, focusPrevious
    // panels
    case toggleTasks, goToTasks, goToCalendar, commandPalette, search, showHelp
    // editing
    case newTask, newEvent, edit, delete, complete, pin, unpin, snooze
    case setPriorityAsap, setPriorityHigh, setPriorityMedium, setPriorityLow
    case openInGoogle, copyLink
    case cancel
    case sync

    /// Grouping used by the help overlay, in display order.
    public enum Section: String, Hashable, Sendable, CaseIterable {
        case navigation = "Navigation"
        case views = "Views"
        case panels = "Panels"
        case editing = "Editing"
        case actions = "Actions"
    }

    public var section: Section {
        switch self {
        case .nextDay, .previousDay, .nextWeek, .previousWeek, .today, .goToDate, .focusNext, .focusPrevious:
            .navigation
        case .viewDay, .viewWeek, .viewThreeDays, .viewMonth:
            .views
        case .toggleTasks, .goToTasks, .goToCalendar, .commandPalette, .search, .showHelp:
            .panels
        case .newTask, .newEvent, .edit, .delete, .complete, .pin, .unpin, .snooze,
             .setPriorityAsap, .setPriorityHigh, .setPriorityMedium, .setPriorityLow:
            .editing
        case .openInGoogle, .copyLink, .cancel, .sync:
            .actions
        }
    }

    /// Short English label for menus, the help overlay and the command palette.
    public var label: String {
        switch self {
        case .nextDay: "Next day"
        case .previousDay: "Previous day"
        case .nextWeek: "Next week"
        case .previousWeek: "Previous week"
        case .today: "Go to today"
        case .goToDate: "Go to date…"
        case .viewDay: "Day view"
        case .viewWeek: "Week view"
        case .viewThreeDays: "3-day view"
        case .viewMonth: "Month view"
        case .focusNext: "Focus next item"
        case .focusPrevious: "Focus previous item"
        case .toggleTasks: "Toggle tasks panel"
        case .goToTasks: "Go to tasks"
        case .goToCalendar: "Go to calendar"
        case .commandPalette: "Command palette"
        case .search: "Search"
        case .showHelp: "Keyboard shortcuts"
        case .newTask: "New task"
        case .newEvent: "New event"
        case .edit: "Edit"
        case .delete: "Delete"
        case .complete: "Complete"
        case .pin: "Pin"
        case .unpin: "Unpin"
        case .snooze: "Snooze"
        case .setPriorityAsap: "Priority: ASAP"
        case .setPriorityHigh: "Priority: High"
        case .setPriorityMedium: "Priority: Medium"
        case .setPriorityLow: "Priority: Low"
        case .openInGoogle: "Open in Google Calendar"
        case .copyLink: "Copy link"
        case .cancel: "Cancel"
        case .sync: "Sync now"
        }
    }

    /// The priority a `setPriority…` command assigns; nil for every other command.
    public var priority: Priority? {
        switch self {
        case .setPriorityAsap: .asap
        case .setPriorityHigh: .high
        case .setPriorityMedium: .medium
        case .setPriorityLow: .low
        default: nil
        }
    }
}
