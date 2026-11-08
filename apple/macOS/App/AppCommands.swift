import FloridaKit
import SwiftUI

/// The menu bar. Items mirror `Keymap.default`; the ⌘ shortcuts shown here are the same chords
/// the key monitor handles, so a shortcut works whether the main window or Settings is key.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") { model.perform(.newTask) }
                .keyboardShortcut("n")
            Button("New Event in Google Calendar") { model.perform(.newEvent) }
            Divider()
            Button("Sync Now") { model.perform(.sync) }
                .keyboardShortcut("r")
        }

        CommandMenu("Go") {
            Button("Today") { model.perform(.today) }
            Button("Go to Date…") { model.perform(.goToDate) }
            Divider()
            Button("Previous Day") { model.perform(.previousDay) }
            Button("Next Day") { model.perform(.nextDay) }
            Button("Previous Week") { model.perform(.previousWeek) }
            Button("Next Week") { model.perform(.nextWeek) }
            Divider()
            Button("Calendar") { model.perform(.goToCalendar) }
            Button("Tasks") { model.perform(.goToTasks) }
        }

        // Named "Calendar" because SwiftUI already adds a "View" menu (Enter Full Screen).
        CommandMenu("Calendar") {
            Button("Day") { model.perform(.viewDay) }
            Button("3 Days") { model.perform(.viewThreeDays) }
            Button("Week") { model.perform(.viewWeek) }
            Button("Month") { model.perform(.viewMonth) }
            Divider()
            Button("Toggle Tasks") { model.perform(.toggleTasks) }
                .keyboardShortcut("t")
            Button("Command Palette") { model.perform(.commandPalette) }
                .keyboardShortcut("k")
            Button("Search") { model.perform(.search) }
                .keyboardShortcut("f")
            Button("Keyboard Shortcuts") { model.perform(.showHelp) }
        }

        CommandMenu("Task") {
            Button("Edit") { model.perform(.edit) }
            Button("Complete") { model.perform(.complete) }
            Button("Delete") { model.perform(.delete) }
            Divider()
            Button("Pin") { model.perform(.pin) }
            Button("Unpin") { model.perform(.unpin) }
            Button("Snooze to Tomorrow") { model.perform(.snooze) }
            Divider()
            Button("Priority: ASAP") { model.perform(.setPriorityAsap) }
                .keyboardShortcut("1")
            Button("Priority: High") { model.perform(.setPriorityHigh) }
                .keyboardShortcut("2")
            Button("Priority: Medium") { model.perform(.setPriorityMedium) }
                .keyboardShortcut("3")
            Button("Priority: Low") { model.perform(.setPriorityLow) }
                .keyboardShortcut("4")
            Divider()
            Button("Open in Google Calendar") { model.perform(.openInGoogle) }
            Button("Copy Link") { model.perform(.copyLink) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
    }
}
