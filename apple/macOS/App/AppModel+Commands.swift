import AppKit
import FloridaKit

extension AppModel {
    /// Google Calendar's "new event" page; Florida has no event write API, so `newEvent` opens it.
    static let newGoogleEventURL = URL(string: "https://calendar.google.com/calendar/u/0/r/eventedit")!

    /// True while a sheet owns the window. Commands do nothing then (except Escape and sync):
    /// a sheet holds a draft, and a menu shortcut such as ⌘1 writing underneath it would be
    /// overwritten by the stale draft when the sheet saves.
    var isSheetOpen: Bool {
        editorTask != nil || isGoToDateOpen || isNewCategoryOpen || doneForNow != nil || recurringTaskToDelete != nil
    }

    /// Asks `RootView` to open the Settings window on `tab`.
    func openSettings(_ tab: SettingsTab) {
        settingsTab = tab
        settingsRequest += 1
    }

    /// Runs a Mac command: shared commands go to `perform`, Mac-only ones are handled here.
    func run(_ command: MacCommand) {
        switch command {
        case .core(let shared):
            perform(shared)
        case .undo, .move, .acceptSuggestion, .newCategory, .editSchedule, .newTaskEditor,
             .doNow, .doneForNow, .repeatLast, .centerOnNow, .jumpToFirst, .jumpToLast:
            guard !isSheetOpen else { return }
            statusMessage = nil
            switch command {
            case .undo: undo()
            case .move: openMovePicker()
            case .acceptSuggestion: acceptSuggestion()
            case .newCategory: isNewCategoryOpen = true
            case .editSchedule: openSettings(.schedules)
            case .newTaskEditor: openNewTaskEditor()
            case .doNow: doNowSelection()
            case .doneForNow: doneForNowSelection()
            case .repeatLast: repeatLastAction()
            case .centerOnNow: centerOnNow()
            case .jumpToFirst: jumpToEdge(last: false)
            case .jumpToLast: jumpToEdge(last: true)
            case .core: break
            }
        }
    }

    /// Runs one command. Synchronous: every state change lands before this returns, and anything
    /// that needs the network is started in the background.
    func perform(_ command: AppCommand) {
        if isSheetOpen, command != .cancel, command != .sync { return }
        statusMessage = nil
        if RepeatableAction.repeatableCommands.contains(command), selectedTask != nil {
            lastAction = .command(command)
        }
        switch command {
        case .nextDay: moveDay(by: 1)
        case .previousDay: moveDay(by: -1)
        case .nextWeek: moveWeek(by: 1)
        case .previousWeek: moveWeek(by: -1)
        case .today: goToToday()
        case .goToDate: isGoToDateOpen = true
        case .viewDay: setViewMode(.day)
        case .viewWeek: setViewMode(.week)
        case .viewThreeDays: setViewMode(.threeDays)
        case .viewMonth: setViewMode(.month)
        case .focusNext: moveFocus(by: 1)
        case .focusPrevious: moveFocus(by: -1)
        case .toggleTasks:
            isTasksPaneVisible.toggle()
            if !isTasksPaneVisible, focus == .tasks {
                focus = .calendar
            }
        case .goToTasks:
            isTasksPaneVisible = true
            focus = .tasks
        case .goToCalendar: focus = .calendar
        case .commandPalette: togglePalette(mode: .command)
        case .search: openPalette(mode: .search)
        case .showHelp: isHelpOpen.toggle()
        case .newTask: openPalette(mode: .quickAdd)
        case .newEvent: open(url: Self.newGoogleEventURL)
        case .edit: editSelection()
        case .delete: deleteSelection()
        case .complete: completeSelection()
        case .pin: pinSelection(true)
        case .unpin: pinSelection(false)
        case .snooze: snoozeSelection()
        case .setPriorityAsap, .setPriorityHigh, .setPriorityMedium, .setPriorityLow:
            if let priority = command.priority {
                setPriority(priority)
            }
        case .openInGoogle: openSelectionInGoogle()
        case .copyLink: copyLink()
        case .cancel: cancel()
        case .sync: scheduleSync()
        }
    }

    /// Escape: closes the topmost overlay, else clears the selection and any pending key sequence.
    func cancel() {
        pendingKeys = ""
        matcher.reset()
        if isPaletteOpen {
            closePalette()
        } else if isHelpOpen {
            isHelpOpen = false
        } else if eventDetailID != nil {
            eventDetailID = nil
        } else if recurringTaskToDelete != nil {
            recurringTaskToDelete = nil
        } else if editorTask != nil {
            editorTask = nil
        } else if isGoToDateOpen {
            isGoToDateOpen = false
        } else if isNewCategoryOpen {
            isNewCategoryOpen = false
        } else if doneForNow != nil {
            doneForNow = nil
        } else {
            selection = nil
        }
    }

    /// Return / `e` / double-click: tasks open the editor sheet, events their detail popover.
    func editSelection() {
        if case .gap(let id)? = selection, let gap = gridLayout.gap(id: id) {
            openFitPicker(gap)
        } else if let task = selectedTask {
            editorTask = task
        } else if let event = selectedEvent {
            eventDetailID = event.id
        } else {
            statusMessage = "Select a task or event first"
        }
    }

    func openSelectionInGoogle() {
        guard let event = selectedEvent else {
            statusMessage = selectedTask == nil ? "Select an event first" : "Tasks have no Google Calendar page"
            return
        }
        openInGoogle(event)
    }

    func openInGoogle(_ event: CalendarEvent) {
        guard let link = event.htmlLink, let url = URL(string: link) else {
            statusMessage = "This event has no Google Calendar link"
            return
        }
        open(url: url)
    }

    /// ⇧⌘C: an event's Google Calendar link, or a task's title.
    func copyLink() {
        if let event = selectedEvent {
            copyLink(of: event)
        } else if let task = selectedTask {
            copy(task.title)
        } else {
            statusMessage = "Nothing selected to copy"
        }
    }

    func copyLink(of event: CalendarEvent) {
        copy(event.htmlLink ?? event.summary ?? "")
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showGhost("Copied")
    }

    func open(url: URL) {
        NSWorkspace.shared.open(url)
    }
}
