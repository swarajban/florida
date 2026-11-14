import AppKit
import FloridaKit

extension AppModel {
    var availabilityCalendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = Availability.routineTimeZone(userSettings)
        return result
    }

    var availabilitySchedule: Schedule? {
        guard let share = availabilityShare else { return nil }
        return schedules.first { $0.id == share.scheduleID && $0.deletedAt == nil }
    }

    var availabilityText: String {
        guard let share = availabilityShare else { return "" }
        return Availability.text(share.selected, timeZone: calendar.timeZone, recipientTimeZone: share.recipientZone)
    }

    var availabilitySyncWarning: String? {
        guard let lastSyncAt else { return "Not synced yet — these times may be out of date." }
        let minutes = Int(max(0, clockNow.timeIntervalSince(lastSyncAt)) / 60)
        guard minutes >= 15 else { return nil }
        return "Last synced \(minutes)m ago — these times may be out of date."
    }

    func startAvailability() {
        closePalette()
        jump = nil
        eventDetailID = nil
        resetKeySequence()
        var share = AvailabilityShareState()
        if viewMode == .month {
            share.previousViewMode = viewMode
            viewMode = .week
            rangeDidChange()
        }
        let workIDs = Set(categories.filter { $0.area == .work }.map(\.scheduleId))
        share.scheduleID = schedules.first { workIDs.contains($0.id) }?.id
            ?? schedules.first { $0.name.localizedCaseInsensitiveContains("work") }?.id
            ?? activeSchedules.first?.id
        availabilityShare = share
        startAvailabilityEvents()
        refreshAvailability(propose: true)
        revealAvailabilityCursor()
    }

    func cancelAvailability() {
        availabilityShare = nil
    }

    @discardableResult
    func reloadAvailabilityEvents() -> Bool {
        guard availabilityShare != nil else { return false }
        guard let database else {
            cancelAvailability()
            statusMessage = "The local store is unavailable"
            return false
        }
        do {
            availabilityShare?.events = try database.availabilityEvents(in: visibleRange, calendar: availabilityCalendar)
            return true
        } catch {
            cancelAvailability()
            statusMessage = "Could not read availability: \(error.localizedDescription)"
            return false
        }
    }

    func startAvailabilityEvents() {
        availabilityEventsObserver?.cancel()
        guard reloadAvailabilityEvents(), let database else { return }
        let range = visibleRange
        let busyCalendar = availabilityCalendar
        availabilityEventsObserver = Task { [weak self] in
            do {
                for try await events in database.observeAvailabilityEvents(in: range, calendar: busyCalendar) {
                    guard !Task.isCancelled, let self, self.availabilityShare != nil else { return }
                    self.availabilityShare?.events = events
                    self.refreshAvailability()
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.cancelAvailability()
                self.statusMessage = "Could not observe availability: \(error.localizedDescription)"
            }
        }
    }

    func refreshAvailability(propose: Bool = false) {
        guard var share = availabilityShare else { return }
        share.free = Availability.freeRanges(
            in: visibleRange, schedules: availabilitySchedule.map { [$0] } ?? [], events: share.events,
            tasks: Array(tasksById.values), placements: placements, commitments: routineOccurrences, now: clockNow,
            timeZone: availabilityCalendar.timeZone)
        share.suggestions = share.free.compactMap { range in
            let end = range.start.addingTimeInterval(Double(share.meetingMinutes) * 60)
            return end <= range.end ? AvailabilityRange(start: range.start, end: end) : nil
        }
        if propose {
            var days = Set<Date>()
            share.selected = Array(share.suggestions.filter {
                days.insert(calendar.startOfDay(for: $0.start)).inserted
            }.prefix(3))
            share.cursor = share.selected.first ?? share.suggestions.first
        } else {
            share.selected = Availability.merge(share.selected.flatMap {
                Availability.clipped($0, to: share.free, minimumMinutes: share.meetingMinutes)
            })
            if let cursor = share.cursor,
               Availability.clipped(cursor, to: share.free, minimumMinutes: share.meetingMinutes) != [cursor] {
                share.cursor = share.suggestions.first
            }
        }
        availabilityShare = share
    }

    func setAvailabilityDuration(_ minutes: Int) {
        availabilityShare?.meetingMinutes = min(240, max(15, minutes))
        refreshAvailability(propose: true)
        revealAvailabilityCursor()
    }

    func setAvailabilitySchedule(_ id: String) {
        availabilityShare?.scheduleID = id
        refreshAvailability(propose: true)
        revealAvailabilityCursor()
    }

    func toggleAvailabilityCursor() {
        guard var share = availabilityShare, let cursor = share.cursor else { return }
        share.selected = Availability.selection(
            Availability.toggle(cursor, in: share.selected), minimumMinutes: share.meetingMinutes)
        availabilityShare = share
    }

    func nextAvailabilitySuggestion(backwards: Bool = false) {
        guard var share = availabilityShare, !share.suggestions.isEmpty else { return }
        let current = share.cursor.flatMap { share.suggestions.firstIndex(of: $0) }
        let index = current.map { ($0 + (backwards ? -1 : 1) + share.suggestions.count) % share.suggestions.count }
            ?? (backwards ? share.suggestions.count - 1 : 0)
        share.cursor = share.suggestions[index]
        availabilityShare = share
        revealAvailabilityCursor()
    }

    func moveAvailabilityCursor(days: Int = 0, minutes: Int = 0, extending: Bool = false) {
        guard var share = availabilityShare, let old = share.cursor else { return }
        var range = old
        if extending {
            range.end = old.end.addingTimeInterval(Double(minutes) * 60)
        } else if days != 0 {
            range.start = calendar.date(byAdding: .day, value: days, to: old.start) ?? old.start
            range.end = range.start.addingTimeInterval(old.end.timeIntervalSince(old.start))
        } else {
            range.start = old.start.addingTimeInterval(Double(minutes) * 60)
            range.end = old.end.addingTimeInterval(Double(minutes) * 60)
        }
        guard Availability.clipped(range, to: share.free, minimumMinutes: share.meetingMinutes) == [range] else {
            statusMessage = "Outside free working hours · Tab jumps to the next suggestion"
            return
        }
        if share.selected.contains(where: { $0.start <= old.start && $0.end >= old.end }) {
            share.selected = Availability.selection(
                Availability.subtract(share.selected, removing: old) + [range], minimumMinutes: share.meetingMinutes)
        }
        share.cursor = range
        availabilityShare = share
        statusMessage = nil
        revealAvailabilityCursor()
    }

    func revealAvailabilityCursor() {
        guard let cursor = availabilityShare?.cursor else { return }
        gridScrollRequest = GridScrollRequest(minute: minuteOfDay(cursor.start), centered: true, animated: false)
    }

    func paintAvailability(day: Date, startMinute: Int, endMinute: Int) {
        guard var share = availabilityShare else { return }
        if share.paint == nil {
            let start = BlockDrag.date(onDay: day, minute: startMinute, calendar: calendar)
            share.paint = AvailabilityShareState.Paint(
                day: day, minute: startMinute, original: share.selected,
                removes: share.selected.contains { $0.start <= start && start < $0.end })
        }
        guard let paint = share.paint else { return }
        let range = Availability.paintedRange(
            on: paint.day, fromMinute: paint.minute, toMinute: endMinute, calendar: calendar)
        if paint.removes {
            share.selected = Availability.selection(
                Availability.subtract(paint.original, removing: range), minimumMinutes: share.meetingMinutes)
        } else {
            let additions = Availability.clipped(range, to: share.free, minimumMinutes: share.meetingMinutes)
            share.selected = Availability.merge(paint.original + additions)
            share.cursor = additions.first ?? share.cursor
        }
        availabilityShare = share
    }

    func tapAvailability(day: Date, minute: Int) {
        guard var share = availabilityShare else { return }
        let start = BlockDrag.date(onDay: day, minute: minute, calendar: calendar)
        if let selected = share.selected.first(where: { $0.start <= start && start < $0.end }) {
            share.selected = Availability.subtract(share.selected, removing: selected)
            share.cursor = selected
        } else {
            let range = AvailabilityRange(start: start, end: start.addingTimeInterval(Double(share.meetingMinutes) * 60))
            guard Availability.clipped(range, to: share.free, minimumMinutes: share.meetingMinutes) == [range] else { return }
            share.cursor = range
            share.selected = Availability.merge(share.selected + [range])
        }
        availabilityShare = share
    }

    func copyAvailability() {
        guard reloadAvailabilityEvents() else { return }
        refreshAvailability()
        let text = availabilityText
        guard availabilityShare?.selected.isEmpty == false, !text.isEmpty else {
            statusMessage = "Select at least one free range to copy"
            return
        }
        let warning = availabilitySyncWarning.map { "\n\($0)" } ?? ""
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text + warning, forType: .string) else {
            statusMessage = "Could not copy availability"
            return
        }
        cancelAvailability()
        statusMessage = "Availability copied"
    }

    func handleAvailabilityKey(_ chord: KeyChord) -> Bool {
        switch chord {
        case KeyChord("escape"): cancelAvailability()
        case KeyChord("return"), KeyChord("c"), KeyChord("c", [.command]): copyAvailability()
        case KeyChord("space"): toggleAvailabilityCursor()
        case KeyChord("tab"), KeyChord("]"): nextAvailabilitySuggestion()
        case KeyChord("tab", [.shift]), KeyChord("["): nextAvailabilitySuggestion(backwards: true)
        case KeyChord("left"), KeyChord("h"): moveAvailabilityCursor(days: -1)
        case KeyChord("right"), KeyChord("l"): moveAvailabilityCursor(days: 1)
        case KeyChord("up"), KeyChord("k"): moveAvailabilityCursor(minutes: -15)
        case KeyChord("down"), KeyChord("j"): moveAvailabilityCursor(minutes: 15)
        case KeyChord("up", [.shift]), KeyChord("k", [.shift]): moveAvailabilityCursor(minutes: -15, extending: true)
        case KeyChord("down", [.shift]), KeyChord("j", [.shift]): moveAvailabilityCursor(minutes: 15, extending: true)
        case KeyChord("1"): setAvailabilityDuration(15)
        case KeyChord("2"): setAvailabilityDuration(30)
        case KeyChord("3"): setAvailabilityDuration(45)
        case KeyChord("4"): setAvailabilityDuration(60)
        case KeyChord("+"), KeyChord("="): setAvailabilityDuration((availabilityShare?.meetingMinutes ?? 30) + 15)
        case KeyChord("-"): setAvailabilityDuration((availabilityShare?.meetingMinutes ?? 30) - 15)
        case KeyChord("z"): isAvailabilityZoneOpen = true
        default: return !chord.modifiers.contains(.command)
        }
        return true
    }
}
