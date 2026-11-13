import FloridaKit
import Foundation

/// One line of the menu bar agenda: a meeting or a scheduled task block.
struct AgendaEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    /// Calendar or category color.
    let colorHex: String?
    let joinURL: URL?
    let isTask: Bool
}

// The menu bar extra replaces a separate date / next-meeting app, so its title leads with the
// next meeting and how long until it, and always ends with the full date, with the year, and the
// time. It reads today's agenda from the local store and `clockNow`, which ticks on each minute;
// nothing waits on the network.

extension AppModel {
    /// "Standup in 12m · Mon Nov 9, 2026 2:03 PM", or just the date and time when no meeting is
    /// left today.
    var menuBarTitle: String {
        let now = clockNow
        let date = "\(now.formatted(.dateTime.weekday(.abbreviated))) \(now.formatted(.dateTime.month(.abbreviated).day())), \(now.formatted(.dateTime.year()))"
        let dateAndTime = "\(date) \(DateText.time(now))"
        guard let next = nextMeeting(after: now) else { return dateAndTime }
        return "\(Self.shortTitle(next.title)) \(Self.untilText(next.start, now: now)) · \(dateAndTime)"
    }

    /// The next timed meeting today that has not started, else the one in progress.
    func nextMeeting(after now: Date) -> AgendaEntry? {
        let meetings = remainingAgenda(after: now).filter { !$0.isTask }
        return meetings.first { $0.start > now } ?? meetings.first
    }

    /// Today's timed events and task blocks that have not ended, by start.
    func remainingAgenda(after now: Date) -> [AgendaEntry] {
        guard let agenda = todayAgenda else { return [] }
        let events = agenda.events.compactMap { event -> AgendaEntry? in
            guard !event.allDay, !event.isOutOfOffice, let start = event.startAt, let end = event.endAt, end > now
            else { return nil }
            let summary = event.summary?.trimmingCharacters(in: .whitespaces) ?? ""
            return AgendaEntry(
                id: event.id, title: summary.isEmpty ? "(No title)" : summary, start: start, end: end,
                colorHex: calendarsById[event.calendarId]?.color, joinURL: event.joinURL, isTask: false)
        }
        let blocks = agenda.placements.compactMap { block -> AgendaEntry? in
            guard block.placement.endAt > now, block.task.isOpen else { return nil }
            return AgendaEntry(
                id: block.placement.id, title: block.task.title, start: block.placement.startAt,
                end: block.placement.endAt, colorHex: categoriesById[block.task.categoryId]?.color,
                joinURL: nil, isTask: true)
        }
        return (events + blocks).sorted { $0.start < $1.start }
    }

    /// "in 12m", "in 1h 5m", or "now" once it has started (or starts within the minute).
    static func untilText(_ start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 0 ? "now" : "in \(DateText.duration(minutes: minutes))"
    }

    static func shortTitle(_ title: String) -> String {
        title.count > 24 ? String(title.prefix(23)) + "…" : title
    }

    /// Keeps `clockNow` on the current minute and the agenda on the current day. Started once.
    func startClock() {
        restartAgendaObserver()
        #if DEBUG
        if DemoData.fixedNow != nil { return }
        #endif
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date()
                let next = (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60
                try? await Task.sleep(for: .seconds(next - now.timeIntervalSinceReferenceDate + 0.05))
                guard let self else { return }
                let tick = Date()
                let isNewDay = !self.calendar.isDate(tick, inSameDayAs: self.clockNow)
                self.clockNow = tick
                if JoyPreferences.isOn(.freeGaps) {
                    // Today's gaps start at the next 5-minute mark, so they shrink as time passes.
                    self.rebuildLayout()
                }
                if isNewDay {
                    self.restartAgendaObserver()
                }
            }
        }
    }

    private func restartAgendaObserver() {
        agendaObserver?.cancel()
        guard let database else { return }
        let day = calendar.startOfDay(for: clockNow)
        let sequence = database.observeAgenda(for: day, calendar: calendar)
        agendaObserver = Task { [weak self] in
            do {
                for try await agenda in sequence {
                    self?.todayAgenda = agenda
                }
            } catch {
                self?.statusMessage = "Live query failed: \(error.localizedDescription)"
            }
        }
    }
}
