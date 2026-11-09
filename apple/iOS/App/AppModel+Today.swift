import FloridaKit
import Foundation

// Keeps the agenda on today. `anchoredToday` is the local day the agenda was last anchored to:
// becoming active on a later day selects today outright, and midnight while the app stays active
// moves an agenda that was showing the old today to the new one (a day the user browsed to stays).

extension AppModel {
    /// Called when the app becomes active.
    func anchorToTodayIfDayChanged() {
        let today = today
        guard today != anchoredToday else { return }
        anchoredToday = today
        resetDailyState()
        select(day: today)
    }

    /// Wakes at every local midnight while the app is active; cancelled when it leaves the foreground.
    func startMidnightWatcher() {
        midnightWatcher?.cancel()
        midnightWatcher = Task { [weak self] in
            while let delay = self?.secondsUntilNextMidnight() {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                self?.rollOverMidnight()
            }
        }
    }

    func stopMidnightWatcher() {
        midnightWatcher?.cancel()
        midnightWatcher = nil
    }

    private func rollOverMidnight() {
        let today = today
        guard today != anchoredToday else { return }
        let wasShowingToday = selectedDay == anchoredToday
        anchoredToday = today
        resetDailyState()
        if wasShowingToday {
            select(day: today)
        }
    }

    /// A second past the next local midnight, so `startOfDay` has certainly moved on.
    private func secondsUntilNextMidnight() -> Double {
        let next = calendar.date(byAdding: .day, value: 1, to: today) ?? Date().addingTimeInterval(86_400)
        return max(1, next.timeIntervalSinceNow + 1)
    }
}
