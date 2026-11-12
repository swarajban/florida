import Foundation

public struct EventQuickAddSession: Sendable {
    public private(set) var text = ""
    public private(set) var draft: EventQuickAddDraft
    public private(set) var chosenCalendarID: String?
    public private(set) var hasCorrections = false
    private let template: CalendarEvent
    private let now: Date
    private let calendar: Calendar
    private var correctedTitle = false
    private var correctedSchedule = false
    private var correctedLocation = false
    private var correctedRecurrence = false
    private var timedShape: (hour: Int, minute: Int, duration: TimeInterval)?

    public init(event: CalendarEvent, now: Date, calendar: Calendar) {
        template = event
        self.now = now
        self.calendar = calendar
        draft = EventQuickAddParser.parse("", now: now, calendar: calendar, defaultStart: event.startAt)
    }

    public mutating func updateText(_ text: String) {
        var parsed = EventQuickAddParser.parse(text, now: now, calendar: calendar, defaultStart: template.startAt)
        if parsed.calendarHint != draft.calendarHint { chosenCalendarID = nil }
        if correctedTitle { parsed.title = draft.title }
        if correctedSchedule {
            parsed.startAt = draft.startAt
            parsed.endAt = draft.endAt
            parsed.allDay = draft.allDay
        }
        if correctedLocation { parsed.location = draft.location }
        if correctedRecurrence { parsed.recurrence = draft.recurrence }
        draft = parsed
        self.text = text
    }

    public mutating func resetCorrections() {
        correctedTitle = false
        correctedSchedule = false
        correctedLocation = false
        correctedRecurrence = false
        chosenCalendarID = nil
        hasCorrections = false
        timedShape = nil
        updateText(text)
    }

    public mutating func setTitle(_ title: String) {
        draft.title = title
        correctedTitle = true
        hasCorrections = true
    }

    public mutating func setLocation(_ location: String) {
        draft.location = location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : location
        correctedLocation = true
        hasCorrections = true
    }

    public mutating func setRecurrence(_ recurrence: EventRecurrence?) {
        draft.recurrence = recurrence
        correctedRecurrence = true
        hasCorrections = true
    }

    public mutating func chooseCalendar(_ id: String) {
        chosenCalendarID = id
        hasCorrections = true
    }

    public var localStart: Date {
        draft.allDay ? AllDayDate.localDays(start: draft.startAt, end: draft.endAt, calendar: calendar).lowerBound : draft.startAt
    }

    public var localEnd: Date {
        guard draft.allDay else { return draft.endAt }
        let end = AllDayDate.localDays(start: draft.startAt, end: draft.endAt, calendar: calendar).upperBound
        return calendar.date(byAdding: .day, value: -1, to: end) ?? end
    }

    public mutating func moveStart(to date: Date) {
        if draft.allDay {
            let day = calendar.startOfDay(for: date)
            let days = calendar.dateComponents([.day], from: localStart, to: day).day ?? 0
            let last = calendar.date(byAdding: .day, value: days, to: localEnd) ?? day
            draft.startAt = AllDayDate.storedInstant(forLocalDay: day, calendar: calendar)
            draft.endAt = storedEnd(after: last)
        } else {
            draft.endAt = date.addingTimeInterval(draft.endAt.timeIntervalSince(draft.startAt))
            draft.startAt = date
        }
        correctedSchedule = true
        hasCorrections = true
    }

    public mutating func setEnd(_ date: Date) {
        draft.endAt = draft.allDay ? storedEnd(after: date) : date
        correctedSchedule = true
        hasCorrections = true
    }

    public mutating func setAllDay(_ allDay: Bool) {
        guard allDay != draft.allDay else { return }
        if allDay {
            let clock = calendar.dateComponents([.hour, .minute], from: draft.startAt)
            timedShape = (clock.hour ?? 9, clock.minute ?? 0, draft.endAt.timeIntervalSince(draft.startAt))
            let last = max(draft.startAt, draft.endAt.addingTimeInterval(-1))
            draft.startAt = AllDayDate.storedInstant(forLocalDay: draft.startAt, calendar: calendar)
            draft.endAt = storedEnd(after: last)
        } else {
            let shape = timedShape ?? (hour: 9, minute: 0, duration: 30 * 60)
            let start = calendar.date(bySettingHour: shape.hour, minute: shape.minute, second: 0, of: localStart) ?? localStart
            draft.startAt = start
            draft.endAt = start.addingTimeInterval(shape.duration)
        }
        draft.allDay = allDay
        correctedSchedule = true
        hasCorrections = true
    }

    public func destination(in calendars: [CalendarInfo], accounts: [GoogleAccount]) -> CalendarInfo? {
        let writable = calendars.filter { $0.accessRole == "owner" || $0.accessRole == "writer" }
        if let chosenCalendarID { return writable.first { $0.id == chosenCalendarID } }
        if let hint = draft.calendarHint {
            let matches = EventQuickAddParser.matchingCalendars(hint: hint, in: writable, accounts: accounts)
            return matches.count == 1 ? matches[0] : nil
        }
        return writable.sorted { CalendarInfo.isPreferredForNewEvents($0, $1, accounts: accounts) }.first
    }

    public func validationMessage(in calendars: [CalendarInfo], accounts: [GoogleAccount]) -> String? {
        guard let destination = destination(in: calendars, accounts: accounts) else {
            return calendars.contains { $0.accessRole == "owner" || $0.accessRole == "writer" }
                ? "Choose a calendar. The calendar hint needs one clear match."
                : "No writable calendars. Connect an account and sync first."
        }
        guard accounts.contains(where: { $0.id == destination.accountId }) else {
            return "The calendar’s account is unavailable. Sync your accounts before saving."
        }
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this event a title." }
        if draft.endAt <= draft.startAt { return "The end must be after the start." }
        return nil
    }

    public func event(in calendars: [CalendarInfo], accounts: [GoogleAccount], allowUntitled: Bool = false) -> CalendarEvent? {
        guard (allowUntitled || !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              draft.endAt > draft.startAt,
              let destination = destination(in: calendars, accounts: accounts),
              accounts.contains(where: { $0.id == destination.accountId }) else { return nil }
        return CalendarEvent(
            id: template.id, calendarId: destination.id, googleId: "", status: "confirmed",
            summary: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            location: draft.location?.trimmingCharacters(in: .whitespacesAndNewlines),
            startAt: draft.startAt, endAt: draft.endAt, allDay: draft.allDay,
            description: draft.notes, updatedAt: now)
    }

    private func storedEnd(after date: Date) -> Date {
        let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
        return AllDayDate.storedInstant(forLocalDay: next, calendar: calendar)
    }
}
