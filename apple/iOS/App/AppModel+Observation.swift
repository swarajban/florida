import FloridaKit
import Foundation

// GRDB observation: each loop yields the current rows at once and again after every commit that
// touched them, so local writes and applied syncs reach the views without any explicit refresh.

extension AppModel {
    func startObserving() {
        observe("categories", { $0.observeCategories() }) { $0.categories = $1 }
        observe("schedules", { $0.observeSchedules() }) { $0.schedules = $1 }
        observe("the routine", { $0.observeRoutineBlocks() }) { $0.routineBlocks = $1 }
        observe("settings", { $0.observeUserSettings() }) { $0.userSettings = $1 }
        observe("tasks", { $0.observeOpenTasks() }) { $0.openTasks = $1 }
        observe("the schedule", { $0.observePlacements() }) { model, placements in
            model.placementsByTask = Dictionary(grouping: placements, by: \.taskId)
        }
        observe("unscheduled tasks", { $0.observeUnscheduled() }) { model, rows in
            model.unscheduledByTask = Dictionary(rows.map { ($0.taskId, $0) }, uniquingKeysWith: { $1 })
        }
        observe("suggestions", { $0.observeOptionalPlacements() }) { $0.optionalPlacements = $1 }
        observe("accounts", { $0.observeAccounts() }) { $0.accounts = $1 }
        observe("calendars", { $0.observeCalendars() }) { $0.calendars = $1 }
        observe("pending writes", { $0.observePendingWriteCount() }) { model, _ in model.refreshPendingWrites() }
        observeAgenda()
    }

    /// (Re)starts the agenda observation for `selectedDay`; the previous one is cancelled.
    ///
    /// The first value is read synchronously: the observation delivers its first rows a run
    /// loop later, which left the strip on the new day over the old day's list for a frame (and,
    /// when the new day was today, put a now marker into it). A day's rows are one indexed read
    /// of the local store, so the strip, title and list now change together.
    func observeAgenda() {
        agendaObserver?.cancel()
        guard let database else { return }
        let day = selectedDay
        let calendar = calendar
        if let current = try? database.agenda(for: day, calendar: calendar) {
            agenda = current
        }
        agendaObserver = Task { [weak self] in
            do {
                for try await agenda in database.observeAgenda(for: day, calendar: calendar) {
                    self?.agenda = agenda
                }
            } catch {
                self?.lastError = "Could not read the agenda: \(error.localizedDescription)"
            }
        }
    }

    /// Runs one observation for the life of the model, handing every value to `apply`. The
    /// sequence is created inside the task, so only the `Sendable` store crosses into it.
    private func observe<Values: AsyncSequence>(
        _ what: String, _ makeValues: @escaping @Sendable (AppDatabase) -> Values,
        apply: @escaping @MainActor (AppModel, Values.Element) -> Void
    ) {
        guard let database else { return }
        observers.append(Task { [weak self] in
            do {
                for try await value in makeValues(database) {
                    guard let self else { return }
                    apply(self, value)
                }
            } catch {
                self?.lastError = "Could not read \(what): \(error.localizedDescription)"
            }
        })
    }
}
