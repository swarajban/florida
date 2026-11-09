import FloridaKit
import Foundation

// The hour grid (`DayGridView`) shows one or three days from `selectedDay`, while `agenda` only
// covers `selectedDay`. The view tells the model its range; the model keeps `gridDays` current
// with one agenda observation per visible day, the way `observeAgenda` keeps `agenda`.

/// The grid's live observation: the local midnights watched and the task reading each.
struct GridObservation {
    var days: [Date]
    var tasks: [Task<Void, Never>]
}

extension AppModel {
    /// The local midnights of `dayCount` days from `start`; `start` is normalized to its midnight.
    static func gridDays(from start: Date, dayCount: Int, calendar: Calendar) -> [Date] {
        let first = calendar.startOfDay(for: start)
        return (0..<max(1, dayCount)).map { DateNavigation.shift(first, by: $0, calendar: calendar) }
    }

    /// (Re)starts the grid observations for `dayCount` days from `start`. A call for the range
    /// already observed does nothing, so the view calls it on every appearance and day change.
    ///
    /// As in `observeAgenda`, every day is read synchronously first: the observation delivers
    /// its first rows a run loop later, which would show the new days' headers over the old
    /// days' blocks for a frame.
    func setGridRange(start: Date, dayCount: Int) {
        let days = Self.gridDays(from: start, dayCount: dayCount, calendar: calendar)
        guard days != gridObservation?.days else { return }
        stopObservingGrid()
        guard let database else { return }
        let calendar = calendar
        gridDays = days.compactMap { try? database.agenda(for: $0, calendar: calendar) }
        var tasks: [Task<Void, Never>] = []
        for day in days {
            tasks.append(Task { [weak self] in
                do {
                    for try await agenda in database.observeAgenda(for: day, calendar: calendar) {
                        self?.applyGridAgenda(agenda)
                    }
                } catch {
                    self?.lastError = "Could not read the agenda: \(error.localizedDescription)"
                }
            })
        }
        gridObservation = GridObservation(days: days, tasks: tasks)
    }

    /// Cancels the grid observations when the grid leaves the screen. `gridDays` keeps its last
    /// value: the next `setGridRange` replaces it with a fresh synchronous read.
    func stopObservingGrid() {
        gridObservation?.tasks.forEach { $0.cancel() }
        gridObservation = nil
    }

    /// Puts one day's agenda into `gridDays`. A value for a day no longer observed (a late
    /// delivery from a cancelled task) is dropped, and an unchanged value is not written, so the
    /// grid is not re-laid out for nothing.
    private func applyGridAgenda(_ agenda: DayAgenda) {
        guard gridObservation?.days.contains(agenda.day) == true else { return }
        if let index = gridDays.firstIndex(where: { $0.day == agenda.day }) {
            if gridDays[index] != agenda {
                gridDays[index] = agenda
            }
        } else {
            gridDays.append(agenda)
            gridDays.sort { $0.day < $1.day }
        }
    }
}
