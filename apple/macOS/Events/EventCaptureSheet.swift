import FloridaKit
import SwiftUI

struct EventCaptureSheet: View {
    @Environment(AppModel.self) private var model
    @State private var editorDraft: CalendarEvent?
    @State private var recurrence: EventRecurrence?
    let request: EventEditorRequest

    var body: some View {
        if request.isNew && request.showsComposer && editorDraft == nil {
            EventQuickAddComposer(
                event: request.event,
                calendars: model.writableCalendars,
                accounts: model.accounts,
                calendar: model.calendar,
                onSave: save,
                onCancel: { model.eventEditor = nil },
                onOpenEditor: { event, recurrence in
                    self.recurrence = recurrence
                    editorDraft = event
                })
        } else {
            EventEditorSheet(event: editorDraft ?? request.event, isNew: request.isNew, recurrence: recurrence)
        }
    }

    private func save(_ event: CalendarEvent, recurrence: EventRecurrence?) -> Bool {
        guard model.save(event: event, recurrence: recurrence) else { return false }
        model.eventEditor = nil
        if let start = event.startAt {
            let day = event.allDay
                ? AllDayDate.localDays(start: start, end: start, calendar: model.calendar).lowerBound
                : start
            model.selectDay(day)
        }
        model.select(.event(event.id), in: .calendar)
        model.showGhost("Added to \(model.calendarsById[event.calendarId]?.summary ?? "calendar")")
        return true
    }
}
