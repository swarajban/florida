import Foundation
import Observation

struct CalendarActivationState {
    struct Entry {
        var started: TimeInterval
        var attempt = 0
    }

    var entries: [String: Entry] = [:]
    static let pullOffsets: [TimeInterval] = [1.5, 4.5, 10.5, 18]

    mutating func reconcile(_ calendars: [CalendarInfo]) {
        entries = entries.filter { id, _ in
            guard let calendar = calendars.first(where: { $0.id == id }), calendar.selected else { return false }
            return calendar.lastSyncedAt == nil
        }
    }

    mutating func tick(now: TimeInterval) -> Bool {
        var shouldPull = false
        for (id, var entry) in entries {
            let elapsed = now - entry.started
            if elapsed >= 20 {
                entries[id] = nil
            } else if entry.attempt < Self.pullOffsets.count, elapsed >= Self.pullOffsets[entry.attempt] {
                entry.attempt += 1
                entries[id] = entry
                shouldPull = true
            }
        }
        return shouldPull
    }
}

@MainActor @Observable
public final class CalendarActivation {
    private var state = CalendarActivationState()
    @ObservationIgnored private var timer: Task<Void, Never>?
    public var syncingCalendarIds: Set<String> { Set(state.entries.keys) }

    public init() {}

    public func setSelected(_ selected: Bool, calendar: CalendarInfo, requestSync: @escaping @MainActor () -> Void) {
        state.entries[calendar.id] = selected
            ? .init(started: ProcessInfo.processInfo.systemUptime) : nil
        guard !state.entries.isEmpty, timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                if self.state.tick(now: ProcessInfo.processInfo.systemUptime) { requestSync() }
                if self.state.entries.isEmpty {
                    self.timer = nil
                    return
                }
            }
        }
    }

    public func reconcile(_ calendars: [CalendarInfo]) {
        state.reconcile(calendars)
    }

    public func status(in calendars: [CalendarInfo]) -> String? {
        let names = calendars.filter { syncingCalendarIds.contains($0.id) }.map(\.summary)
        guard !names.isEmpty else { return nil }
        return names.count == 1 ? "Syncing \(names[0])…" : "Syncing \(names.count) calendars…"
    }
}
