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
/// or search hits. Quick add becomes command mode while the text starts with ">".
struct PaletteState {
    enum Mode: Hashable {
        case quickAdd, command, search
    }

    var text = ""
    var selectedIndex = 0
    var draft = QuickAddDraft()
    var commands: [AppCommand] = AppCommand.allCases
    var searchResults: [SearchResult] = []
    private var baseMode: Mode = .quickAdd

    init(mode: Mode = .quickAdd) {
        switch mode {
        case .quickAdd:
            baseMode = .quickAdd
        case .command:
            baseMode = .quickAdd
            text = ">"
        case .search:
            baseMode = .search
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
        }
    }

    /// Re-parses the draft or re-filters the commands; search results need the store, so
    /// `AppModel.paletteTextDidChange` fills them.
    mutating func textDidChange(now: Date, calendar: Calendar) {
        selectedIndex = 0
        switch mode {
        case .quickAdd:
            draft = QuickAddParser.parse(text, now: now, calendar: calendar)
        case .command:
            commands = FuzzyMatch.filter(AppCommand.allCases, query: query, label: \.label)
        case .search:
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
}
