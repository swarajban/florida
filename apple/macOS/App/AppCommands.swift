import FloridaKit
import SwiftUI

private struct MainCalendarWindowKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var mainCalendarWindow: Bool? {
        get { self[MainCalendarWindowKey.self] }
        set { self[MainCalendarWindowKey.self] = newValue }
    }
}

/// The menu bar. Items mirror `MacKeymap.default`; task actions belong to the main calendar
/// scene, while global commands also work with Settings in front.
/// Single-letter keys are not menu shortcuts: a menu key equivalent would also fire while typing.
/// Main-actor isolated (as the `Commands` conformance implies) so the items can read the model.
@MainActor
struct AppCommands: Commands {
    let model: AppModel
    @FocusedValue(\.mainCalendarWindow) private var mainCalendarWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Quick Add Task") { model.perform(.newTask) }
                .keyboardShortcut("n")
            Button("New Task…") { model.run(.newTaskEditor) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Event…") { model.perform(.newEvent) }
            Button("New Category…") { model.run(.newCategory) }
            Button("Routine…") { model.run(.showRoutine) }
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
            Divider()
            Button("Projects") { model.run(.showProjects) }
            Button("Brief") { model.run(.showBrief) }
        }

        // Named "Calendar" because SwiftUI already adds a "View" menu (Enter Full Screen).
        CommandMenu("Calendar") {
            Button("Day") { model.perform(.viewDay) }
            Button("3 Days") { model.perform(.viewThreeDays) }
            Button("Week") { model.perform(.viewWeek) }
            Button("Month") { model.perform(.viewMonth) }
            Divider()
            // The highlighted day: where it is worked from, which decides what fits on it.
            Menu("Set Day") {
                Button("Home") { model.run(.setDayHome) }
                Button("Office") { model.run(.setDayOffice) }
                Button("Off") { model.run(.setDayOff) }
                Divider()
                Button("Follow the Routine") { model.run(.clearDayKind) }
            }
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
            // A sheet holds a draft of the task; writing underneath it would be lost when it saves.
            Group {
                Button(model.undoStack.last.map { "Undo \($0.label)" } ?? "Undo") { model.run(.undo) }
                    .disabled(model.undoStack.isEmpty)
                Divider()
                Button("Edit") { model.perform(.edit) }
                Button("Done") { model.perform(.complete) }
                Button("Done for Now…") { model.run(.doneForNow) }
                Button("Delete") { model.perform(.delete) }
                Divider()
                Button("Do Now") { model.run(.doNow) }
                Button("Pin") { model.perform(.pin) }
                Button("Unpin") { model.perform(.unpin) }
                Button("Push to Tomorrow") { model.perform(.snooze) }
                Button("Move to…") { model.run(.move) }
                Button("Why Here?") { model.run(.explain) }
                Button("Repeat Last Action") { model.run(.repeatLast) }
                    .disabled(model.lastAction == nil)
                Button("Accept Suggested Category") { model.run(.acceptSuggestion) }
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
            .disabled(model.isSheetOpen || mainCalendarWindow != true)
        }
    }
}
