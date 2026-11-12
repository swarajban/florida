import FloridaKit

/// Everything the Mac keyboard, menus and palette can run: FloridaCore's shared `AppCommand`s
/// plus the commands only the Mac app has. The shared enum is closed (it lives in FloridaCore and
/// the iOS app uses it too), so Mac-only commands are cases here instead.
enum MacCommand: Hashable, Sendable {
    case core(AppCommand)
    /// `z` (or `u`): puts back what the last write changed, on a task or a dragged event.
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
    /// `g n`: center the grid on the current time.
    case centerOnNow
    /// `gg` / `G`: the first or last item of the focused pane.
    case jumpToFirst, jumpToLast
    /// Opens Settings on the Routine tab: the weekly blocks tasks are scheduled in.
    case showRoutine
    /// ⇧E: the editor sheet for the selected event, or the one whose detail popover is open.
    case editEvent
    /// `r y` / `r m` / `r n`: answer the invitation of the selected or open event.
    case respondYes, respondMaybe, respondNo
    /// `g p`: the projects overlay.
    case showProjects
    /// `g b`: today's brief and the weekly review.
    case showBrief
    /// `y`: asks why the selected task is planned where it is.
    case explain
    /// Makes the highlighted day a home, office or off day, or puts it back on the routine.
    case setDayHome, setDayOffice, setDayOff, clearDayKind
    /// `f`: jump mode, which labels every item on screen; typing a label opens its item.
    case jump
    /// `v`: opens the video call of the selected event, or the one whose detail popover is open.
    case joinMeeting
    case openEventResources

    /// Grouping in the help overlay, reusing the shared sections.
    var section: AppCommand.Section {
        switch self {
        case .core(let command): command.section
        case .undo, .move, .acceptSuggestion, .newTaskEditor, .doNow, .doneForNow, .repeatLast,
             .editEvent, .respondYes, .respondMaybe, .respondNo, .joinMeeting, .openEventResources:
            .editing
        case .newCategory, .showRoutine, .explain, .setDayHome, .setDayOffice, .setDayOff, .clearDayKind: .actions
        case .centerOnNow, .jumpToFirst, .jumpToLast, .jump: .navigation
        case .showProjects, .showBrief: .panels
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
        case .showRoutine: "Routine"
        case .centerOnNow: "Center on now"
        case .jumpToFirst: "First item"
        case .jumpToLast: "Last item"
        case .editEvent: "Edit event"
        case .respondYes: "RSVP: Yes"
        case .respondMaybe: "RSVP: Maybe"
        case .respondNo: "RSVP: No"
        case .showProjects: "Projects"
        case .showBrief: "Brief"
        case .explain: "Why here?"
        case .setDayHome: "Set day: Home"
        case .setDayOffice: "Set day: Office"
        case .setDayOff: "Set day: Off"
        case .clearDayKind: "Set day: Follow the routine"
        case .jump: "Jump to…"
        case .joinMeeting: "Join meeting"
        case .openEventResources: "Open event resources"
        }
    }

    /// Runs while an event's detail popover has the keyboard: the commands that act on that
    /// event, and Escape. Everything else waits until the popover is closed.
    var actsOnOpenEvent: Bool {
        switch self {
        case .core(.edit), .core(.delete), .core(.openInGoogle), .core(.copyLink), .core(.cancel),
             .editEvent, .respondYes, .respondMaybe, .respondNo, .joinMeeting, .openEventResources, .undo:
            true
        default:
            false
        }
    }

    /// Every command in palette and help order: the shared commands first, then the Mac ones.
    static let all: [MacCommand] = AppCommand.allCases.map(MacCommand.core) + [
        .newTaskEditor, .doNow, .doneForNow, .repeatLast, .undo, .move, .acceptSuggestion,
        .editEvent, .respondYes, .respondMaybe, .respondNo, .joinMeeting, .openEventResources,
        .newCategory, .showRoutine, .centerOnNow, .jumpToFirst, .jumpToLast, .jump,
        .showProjects, .showBrief, .explain, .setDayHome, .setDayOffice, .setDayOff, .clearDayKind,
    ]

    /// The palette lists everything except Escape.
    static let paletteCommands: [MacCommand] = all.filter { $0 != .core(.cancel) }
}
