import FloridaKit
import Foundation

/// A task or event the palette's search mode can jump to.
struct SearchResult: Identifiable, Hashable {
    let id: ItemID
    let title: String
    let subtitle: String
    /// Where `AppModel.reveal` navigates; nil for unscheduled tasks.
    let day: Date?
}

/// The palette's text and what it currently means: a quick-add draft, a filtered command list,
/// search hits, or the categories a task can move to. Quick add becomes command mode while the
/// text starts with ">".
struct PaletteState {
    enum Mode: Hashable {
        case quickAdd, command, search
        /// Move to…: pick a category for this task.
        case move(taskId: String)
        /// Fill a free gap: the tasks that fit in `minutes` from `start`.
        case fit(start: Date, minutes: Int)
        case eventResources(eventId: String)
    }

    var text = ""
    var selectedIndex = 0
    var draft = QuickAddDraft()
    private var removedSourceURL: String?
    var commands: [MacCommand] = MacCommand.paletteCommands
    var searchResults: [SearchResult] = []
    var categoryResults: [TaskCategory] = []
    var taskResults: [TaskItem] = []
    var resourceResults: [EventResource] = []
    private var baseMode: Mode = .quickAdd

    init(mode: Mode = .quickAdd) {
        switch mode {
        case .quickAdd:
            baseMode = .quickAdd
        case .command:
            baseMode = .quickAdd
            text = ">"
        case .search, .move, .fit, .eventResources:
            baseMode = mode
        }
    }

    var mode: Mode {
        baseMode == .quickAdd && text.hasPrefix(">") ? .command : baseMode
    }

    /// The text without the ">" prefix, trimmed.
    var query: String {
        (mode == .command ? String(text.dropFirst()) : text).trimmingCharacters(in: .whitespaces)
    }

    var resultCount: Int {
        switch mode {
        case .quickAdd: 0
        case .command: commands.count
        case .search: searchResults.count
        case .move: categoryResults.count
        case .fit: taskResults.count
        case .eventResources: resourceResults.count
        }
    }

    /// Re-parses the draft or re-filters the commands; search and move results need the store,
    /// so `AppModel.paletteTextDidChange` fills them.
    mutating func textDidChange(now: Date, calendar: Calendar) {
        selectedIndex = 0
        switch mode {
        case .quickAdd:
            draft = QuickAddParser.parse(text, now: now, calendar: calendar)
            if draft.source?.url == removedSourceURL {
                draft.source = nil
            } else {
                removedSourceURL = nil
            }
        case .command:
            commands = FuzzyMatch.filter(MacCommand.paletteCommands, query: query, label: \.label)
        case .search, .move, .fit, .eventResources:
            break
        }
    }

    mutating func moveSelection(by delta: Int) {
        guard resultCount > 0 else {
            selectedIndex = 0
            return
        }
        selectedIndex = min(max(selectedIndex + delta, 0), resultCount - 1)
    }

    mutating func removeSource() {
        removedSourceURL = draft.source?.url
        draft.source = nil
    }
}
