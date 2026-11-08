import AppKit
import FloridaKit

extension AppModel {
    /// Google Calendar's "new event" page; Florida has no event write API, so `newEvent` opens it.
    static let newGoogleEventURL = URL(string: "https://calendar.google.com/calendar/u/0/r/eventedit")!

    /// Runs one command. Synchronous: every state change lands before this returns, and anything
    /// that needs the network is started in the background.
    func perform(_ command: AppCommand) {
        statusMessage = nil
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
        } else if editorTask != nil {
            editorTask = nil
        } else if isGoToDateOpen {
            isGoToDateOpen = false
        } else {
            selection = nil
        }
    }

    /// Return / `e`: tasks open the editor sheet, events open in Google Calendar.
    func editSelection() {
        if let task = selectedTask {
            editorTask = task
        } else if let event = selectedEvent {
            openInGoogle(event)
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
        let text: String?
        if let event = selectedEvent {
            text = event.htmlLink ?? event.summary
        } else {
            text = selectedTask?.title
        }
        guard let text else {
            statusMessage = "Nothing selected to copy"
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusMessage = "Copied"
    }

    func open(url: URL) {
        NSWorkspace.shared.open(url)
    }
}
