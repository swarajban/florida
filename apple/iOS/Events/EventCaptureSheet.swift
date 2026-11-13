import FloridaKit
import SwiftUI

struct EventCaptureSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editor: CalendarEvent?
    @State private var recurrence: EventRecurrence?
    let event: CalendarEvent

    var body: some View {
        Group {
            if let editor {
                EventEditorView(event: editor, isNew: true, recurrence: recurrence)
            } else {
                EventQuickAddComposer(
                    event: event, calendars: model.writableCalendars, accounts: model.accounts,
                    calendar: model.calendar,
                    onSave: { event, recurrence in
                        guard model.save(event: event, recurrence: recurrence) else { return false }
                        dismiss()
                        return true
                    },
                    onCancel: { dismiss() },
                    onOpenEditor: { event, rule in
                        recurrence = rule
                        editor = event
                    })
            }
        }
        .presentationDetents([.large])
    }
}
