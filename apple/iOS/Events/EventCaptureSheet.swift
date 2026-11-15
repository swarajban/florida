import FloridaKit
import SwiftUI

struct EventCaptureSheet: View {
    @Environment(AppModel.self) private var model
    @State private var editor: CalendarEvent?
    @State private var recurrence: EventRecurrence?
    let event: CalendarEvent
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if let editor {
                EventEditorView(event: editor, isNew: true, recurrence: recurrence, onDismiss: onDismiss)
            } else {
                EventQuickAddComposer(
                    event: event, calendars: model.writableCalendars, accounts: model.accounts,
                    calendar: model.calendar,
                    onSave: { event, recurrence in
                        guard model.save(event: event, recurrence: recurrence) else { return false }
                        onDismiss()
                        return true
                    },
                    onCancel: onDismiss,
                    onOpenEditor: { event, rule in
                        recurrence = rule
                        editor = event
                    })
            }
        }
        .presentationDetents([.large])
    }
}
