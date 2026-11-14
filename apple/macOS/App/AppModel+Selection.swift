import FloridaKit
import Foundation

extension AppModel {
    var liveSelectedTask: TaskItem? {
        guard let id = selectedTask?.id else { return nil }
        return try? database?.task(id: id)
    }

    var taskGroups: [TaskListSection] {
        taskListGrouping.sections(
            tasks: openTasks, categories: categories, now: clockNow, calendar: taskListCalendar)
    }

    var taskListCalendar: Calendar {
        var result = calendar
        if let zone = TimeZone(identifier: userSettings?.timeZone ?? "") { result.timeZone = zone }
        return result
    }

    /// `j` / `k` order in the task pane: today's suggestions, then the displayed task sections.
    var orderedTaskItems: [ItemID] {
        paneSuggestions.flatMap { group in group.picks.map { ItemID.suggestion($0.id) } }
            + taskGroups.flatMap { group in group.tasks.map { ItemID.task($0.id) } }
    }

    /// The task the selection stands for: its row or block, or a suggestion of it.
    var selectedTask: TaskItem? {
        switch selection {
        case .task(let id)?: tasksById[id]
        case .suggestion?: selectedSuggestion.flatMap { tasksById[$0.task.id] }
        default: nil
        }
    }

    /// The selected item when it stands for `task`, else the task's own item: what to move the
    /// selection off when the task goes away.
    func item(for task: TaskItem) -> ItemID {
        if let selection, selectedSuggestion?.task.id == task.id { return selection }
        return .task(task.id)
    }

    /// The gym or project time under the focus ring.
    var selectedPlanBlock: PlanBlock? {
        guard case .plan(let id)? = selection else { return nil }
        return planBlocks.first { $0.id == id }
    }

    var selectedEvent: CalendarEvent? {
        guard case .event(let id)? = selection else { return nil }
        return events.first { $0.id == id } ?? blockingAllDayEvents.first { $0.id == id }
    }

    func scheduleState(for task: TaskItem) -> TaskScheduleState {
        TaskScheduleState(
            task: task, placements: placementsByTask[task.id] ?? [],
            unscheduled: unscheduledByTask[task.id], now: clockNow)
    }

    /// Moves the selection through the focused pane's items, clamped at both ends. With nothing
    /// selected, the calendar starts at the highlighted day's first item; otherwise forward
    /// starts at the first item and backward at the last.
    func moveFocus(by delta: Int) {
        let items = focus == .tasks ? orderedTaskItems : gridLayout.orderedItems
        guard !items.isEmpty else { return }
        let index: Int
        if let selection, let current = items.firstIndex(of: selection) {
            index = min(max(current + delta, 0), items.count - 1)
        } else if focus == .calendar,
                  let first = items.firstIndex(where: { gridLayout.day(of: $0) == selectedDay }) {
            index = first
        } else {
            index = delta >= 0 ? 0 : items.count - 1
        }
        select(items[index])
    }

    /// A click in one pane: moves the focus there and selects the item. The status bar's note on
    /// the last selection goes first, as it does on a key press; `select` then says its own.
    func select(_ item: ItemID, in panel: Panel) {
        focus = panel
        statusMessage = nil
        select(item)
    }

    /// Selects an item; a calendar item also moves the day cursor onto its day. A suggestion says
    /// what it is in the status bar, because it looks like a block and is not on the plan; so do
    /// the gym, project time, and work that shares its hour. Any selection, a click included,
    /// ends jump mode.
    func select(_ item: ItemID?) {
        InboxUIDiagnostic.record("select before=\(String(describing: selection)) requested=\(String(describing: item)) focus=\(focus)")
        endJump()
        resetKeySequence()
        selection = item
        InboxUIDiagnostic.record("select.assigned after=\(String(describing: selection))")
        if focus == .calendar, let item, let day = gridLayout.day(of: item) {
            selectedDay = day
        }
        if selectedTask?.someday == true {
            statusMessage = "Someday"
        } else if let pick = selectedSuggestion {
            let take = RoutineText.takeTitle(pick.placement, now: Date(), calendar: calendar)
            statusMessage = "Suggestion, not on the plan · P: \(take.lowercased())"
        } else if let note = planNote(for: item) {
            statusMessage = note
        }
    }

    func clearHiddenSelection() {
        guard let selection,
              gridLayout.day(of: selection) == nil,
              !isTasksPaneVisible || !orderedTaskItems.contains(selection)
        else { return }
        if case .event(let id) = selection,
           let event = blockingAllDayEvents.first(where: { $0.id == id }),
           AllDayBlocking.protectedDays(for: event, calendar: calendar)?.overlaps(visibleRange) == true {
            return
        }
        InboxUIDiagnostic.record("selection.hidden.clear item=\(selection) paneVisible=\(isTasksPaneVisible) orderedContains=\(orderedTaskItems.contains(selection))")
        self.selection = nil
    }

    /// What the status bar says about a calendar block the grid cannot spell out in a narrow
    /// lane: what the gym or project time is, and what runs beside shared work.
    private func planNote(for item: ItemID?) -> String? {
        guard focus == .calendar, let item else { return nil }
        let blocks = gridLayout.blocksByDay.joined().filter { $0.item == item }
        guard let block = blocks.first(where: { !$0.companions.isEmpty }) ?? blocks.first else { return nil }
        let alongside = block.companions.isEmpty ? nil : PlanText.alongside(block.companions)
        switch block.kind {
        case .completed:
            return "Completed at \(DateText.time(block.start))"
        case .commitment:
            return "\(block.title), from your routine · Return: edit the routine"
        case .projectTime:
            return (["Time held for \(block.title)"] + [alongside].compactMap { $0 } + ["Return: projects"])
                .joined(separator: " · ")
        case .event, .task, .suggestion:
            return alongside
        }
    }
}
