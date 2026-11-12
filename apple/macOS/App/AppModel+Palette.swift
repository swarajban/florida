import FloridaKit
import Foundation

extension AppModel {
    func openPalette(mode: PaletteState.Mode) {
        palette = PaletteState(mode: mode)
        isPaletteOpen = true
        paletteTextDidChange()
    }

    /// Quick add with text already in the field, e.g. "11/20/2026 at 2:00pm " after a
    /// double-click on an empty grid slot.
    func openQuickAdd(prefill: String) {
        palette = PaletteState(mode: .quickAdd)
        palette.text = prefill
        isPaletteOpen = true
        paletteTextDidChange()
    }

    func togglePalette(mode: PaletteState.Mode) {
        if isPaletteOpen {
            closePalette()
        } else {
            openPalette(mode: mode)
        }
    }

    func closePalette() {
        isPaletteOpen = false
        palette = PaletteState()
    }

    /// Re-parses the quick-add draft, re-filters commands, or re-runs the search.
    func paletteTextDidChange() {
        palette.textDidChange(now: Date(), calendar: calendar)
        switch palette.mode {
        case .search:
            palette.searchResults = searchItems(palette.query)
        case .move:
            palette.categoryResults = FuzzyMatch.filter(orderedCategories, query: palette.query, label: \.name).inListOrder()
        case .fit(_, let minutes):
            palette.taskResults = FuzzyMatch.filter(tasksThatFit(minutes: minutes), query: palette.query, label: \.title)
        case .eventResources(let eventId):
            let resources = events.first { $0.id == eventId }?.resources ?? []
            palette.resourceResults = FuzzyMatch.filter(resources, query: palette.query, label: \.title)
        case .quickAdd, .command:
            break
        }
    }

    /// The category a quick-add draft would land in, for the chips: its `#hint`'s, else Inbox.
    var paletteCategory: TaskCategory? {
        matchCategory(hint: palette.draft.categoryHint) ?? inboxCategory
    }

    /// The draft's `#hint` when no category matches it, so the preview can offer to create it.
    var paletteUnknownHint: String? {
        guard let hint = palette.draft.categoryHint, matchCategory(hint: hint) == nil,
              !Self.normalizedCategoryName(hint).isEmpty
        else { return nil }
        return hint
    }

    /// ⌘↩ in quick add: hands the text to the full editor, which sends it to the AI parser.
    func parsePaletteWithAI() {
        let text = palette.text.trimmingCharacters(in: .whitespacesAndNewlines)
        closePalette()
        openNewTaskEditor(aiText: text.isEmpty ? nil : text)
    }

    /// Return in the palette: create the task, run the highlighted command, or reveal the result.
    func submitPalette() {
        switch palette.mode {
        case .quickAdd:
            if createTask(from: palette.draft) {
                closePalette()
            }
        case .command:
            guard palette.commands.indices.contains(palette.selectedIndex) else { return }
            let command = palette.commands[palette.selectedIndex]
            closePalette()
            run(command)
        case .eventResources:
            guard palette.resourceResults.indices.contains(palette.selectedIndex) else { return }
            let resource = palette.resourceResults[palette.selectedIndex]
            closePalette()
            openEventResource(resource)
        case .search:
            guard palette.searchResults.indices.contains(palette.selectedIndex) else { return }
            let result = palette.searchResults[palette.selectedIndex]
            closePalette()
            reveal(result)
        case .move(let taskId):
            guard palette.categoryResults.indices.contains(palette.selectedIndex) else { return }
            let category = palette.categoryResults[palette.selectedIndex]
            closePalette()
            if let task = tasksById[taskId] {
                move(task, to: category)
            }
        case .fit(let start, _):
            guard palette.taskResults.indices.contains(palette.selectedIndex) else { return }
            let task = palette.taskResults[palette.selectedIndex]
            closePalette()
            fill(start: start, with: task)
        }
    }

    /// Open tasks and loaded events whose title fuzzy-matches `query`, best matches first.
    func searchItems(_ query: String) -> [SearchResult] {
        let tasks = openTasks.map { task in
            SearchResult(
                id: .task(task.id), title: task.title,
                subtitle: (categoriesById[task.categoryId]?.name ?? "Task") + " · " + scheduleState(for: task).label(calendar: calendar),
                day: placementsByTask[task.id]?.first?.startAt)
        }
        let events = events.map { event in
            SearchResult(
                id: .event(event.id), title: event.summary ?? "(No title)",
                subtitle: event.startAt.map { DateText.dayAndTime($0, calendar: calendar) } ?? "Event",
                day: event.startAt)
        }
        return Array(FuzzyMatch.filter(tasks + events, query: query, label: \.title).prefix(40))
    }

    /// Jumps to the result's day and selects it in the pane that shows it.
    func reveal(_ result: SearchResult) {
        if let day = result.day {
            goTo(day: day)
        }
        focus = result.id.isTask ? .tasks : .calendar
        if focus == .tasks {
            isTasksPaneVisible = true
        }
        selection = result.id
    }
}
