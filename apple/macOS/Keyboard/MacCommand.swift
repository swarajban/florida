import FloridaKit

/// Everything the Mac keyboard, menus and palette can run: FloridaCore's shared `AppCommand`s
/// plus the commands only the Mac app has. The shared enum is closed (it lives in FloridaCore and
/// the iOS app uses it too), so Mac-only commands are cases here instead.
enum MacCommand: Hashable, Sendable {
    case core(AppCommand)
    /// `u`: re-saves the task versions the last write replaced.
    case undo
    /// `m`: Move to… — the category picker for the selected task.
    case move
    /// ⇥: accept the AI's category for the selected Inbox task.
    case acceptSuggestion
    case newCategory
    /// ⇧N, `>New task`: the full editor with quick add's defaults.
    case newTaskEditor
    /// `n`: pin the selected task to start now.
    case doNow
    /// ⇧Space: log the minutes just worked without finishing.
    case doneForNow
    /// `.`: the last action again, on the current selection.
    case repeatLast
    /// `zz`: center the grid on the current time.
    case centerOnNow
    /// `gg` / `G`: the first or last item of the focused pane.
    case jumpToFirst, jumpToLast
    /// Opens Settings on the Schedules tab.
    case editSchedule

    /// Grouping in the help overlay, reusing the shared sections.
    var section: AppCommand.Section {
        switch self {
        case .core(let command): command.section
        case .undo, .move, .acceptSuggestion, .newTaskEditor, .doNow, .doneForNow, .repeatLast: .editing
        case .newCategory, .editSchedule: .actions
        case .centerOnNow, .jumpToFirst, .jumpToLast: .navigation
        }
    }

    var label: String {
        switch self {
        case .core(.newTask): "Quick add"
        case .core(let command): command.label
        case .undo: "Undo"
        case .move: "Move to…"
        case .acceptSuggestion: "Accept suggested category"
        case .newCategory: "New category"
        case .newTaskEditor: "New task"
        case .doNow: "Do now"
        case .doneForNow: "Done for now…"
        case .repeatLast: "Repeat last action"
        case .editSchedule: "Edit schedule"
        case .centerOnNow: "Center on now"
        case .jumpToFirst: "First item"
        case .jumpToLast: "Last item"
        }
    }

    /// Every command in palette and help order: the shared commands first, then the Mac ones.
    static let all: [MacCommand] = AppCommand.allCases.map(MacCommand.core) + [
        .newTaskEditor, .doNow, .doneForNow, .repeatLast, .undo, .move, .acceptSuggestion,
        .newCategory, .editSchedule, .centerOnNow, .jumpToFirst, .jumpToLast,
    ]

    /// The palette lists everything except Escape.
    static let paletteCommands: [MacCommand] = all.filter { $0 != .core(.cancel) }
}
