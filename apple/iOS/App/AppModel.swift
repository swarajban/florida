import FloridaKit
import Foundation
import Observation

/// The one object behind every screen. Opens the shared store, keeps in-memory copies of what the
/// views show (refreshed by GRDB observation), applies local writes to the store first, and owns
/// the `SyncClient` that pushes them and pulls server changes in the background (`AppModel+Sync`).
///
/// Views only ever read the arrays below; nothing here awaits the network on their behalf.
@Observable @MainActor
final class AppModel {
    let calendar: Calendar
    /// nil when the store could not be opened; `storeError` says why.
    let database: AppDatabase?
    private(set) var storeError: String?

    /// Server URL and token from the keychain; nil until Settings saves one. Set by
    /// `saveServerConfig` in `AppModel+Sync.swift`.
    var serverConfig: ServerConfig?
    @ObservationIgnored var syncClient: SyncClient?
    let tokenStore = KeychainTokenStore()

    // MARK: Observed store contents

    /// Local midnight of the day the Agenda tab shows.
    private(set) var selectedDay: Date
    private(set) var projects: [Project] = []
    private(set) var openTasks: [TaskItem] = []
    /// Every scheduler placement, grouped by task; drives the "scheduled at" line of task rows.
    private(set) var placementsByTask: [String: [Placement]] = [:]
    /// Events and task blocks of `selectedDay`; nil until the first observation fires.
    private(set) var agenda: DayAgenda?
    private(set) var accounts: [GoogleAccount] = []
    private(set) var calendars: [CalendarInfo] = []
    private(set) var pendingWriteCount = 0

    // MARK: Sync status

    /// Number of server calls in flight; `isSyncing` is derived from it.
    var activeOperations = 0
    var lastSyncAt: Date?
    /// Most recent sync or write failure, in words the user can act on; nil after a clean sync.
    var lastError: String?
    @ObservationIgnored var runningSync: Task<Void, Never>?
    @ObservationIgnored var syncRequestedAgain = false
    @ObservationIgnored var periodicSync: Task<Void, Never>?

    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var agendaObserver: Task<Void, Never>?

    var isSyncing: Bool { activeOperations > 0 }
    var needsSetup: Bool { serverConfig == nil }
    var today: Date { calendar.startOfDay(for: Date()) }

    init() {
        let calendar = Calendar.autoupdatingCurrent
        self.calendar = calendar
        selectedDay = calendar.startOfDay(for: Date())

        var openedDatabase: AppDatabase?
        var openError: String?
        do {
            openedDatabase = try Self.openStore()
        } catch {
            openError = "Could not open the local store: \(error.localizedDescription)"
        }
        database = openedDatabase
        storeError = openError

        if LaunchOptions.demoData {
            #if DEBUG
            configureForDemo()
            #endif
        } else {
            loadServerConfig()
        }

        startObserving()
    }

    /// The shared store in the App Group container, or a private in-memory one for demo runs.
    private static func openStore() throws -> AppDatabase {
        if LaunchOptions.demoData {
            return try AppDatabase.inMemory()
        }
        return try AppDatabase(path: AppDatabase.defaultURL().path(percentEncoded: false))
    }

    /// Reads the server settings from the keychain and, when there are some, creates the sync client.
    private func loadServerConfig() {
        do {
            serverConfig = try tokenStore.load()
        } catch {
            lastError = "Could not read the saved server settings: \(error.localizedDescription)"
        }
        if let serverConfig, let database {
            syncClient = SyncClient(database: database, config: serverConfig)
        }
    }

    // MARK: - Day selection

    func select(day: Date) {
        let start = calendar.startOfDay(for: day)
        guard start != selectedDay else { return }
        selectedDay = start
        observeAgenda()
    }

    func shiftDay(by days: Int) {
        select(day: DateNavigation.shift(selectedDay, by: days, calendar: calendar))
    }

    func selectToday() {
        select(day: Date())
    }

    func project(id: String) -> Project? {
        projects.first { $0.id == id }
    }

    // MARK: - Local writes

    /// Creates a task from quick-add text with the app's defaults (30 minutes, medium priority,
    /// the hinted project or Inbox). Returns nil, with `lastError` set, when there is no project yet.
    @discardableResult
    func createTask(from draft: QuickAddDraft) -> TaskItem? {
        guard let project = QuickAddTaskBuilder.resolveProject(hint: draft.projectHint, in: projects) else {
            lastError = "No projects yet. Connect to the server in Settings and sync first."
            return nil
        }
        let task = QuickAddTaskBuilder.makeTask(from: draft, project: project, now: Date())
        save(task)
        return task
    }

    func save(_ task: TaskItem) {
        write { try $0.saveTask(task) }
    }

    func complete(_ task: TaskItem) {
        write { try $0.completeTask(id: task.id) }
    }

    func reopen(_ task: TaskItem) {
        write { try $0.reopenTask(id: task.id) }
    }

    func delete(_ task: TaskItem) {
        write { try $0.deleteTask(id: task.id) }
    }

    /// Applies a write to the store, then starts a background sync. Observation refreshes the
    /// arrays, so the UI updates without waiting for the server.
    private func write(_ change: (AppDatabase) throws -> Void) {
        guard let database else {
            lastError = storeError ?? "The local store is unavailable."
            return
        }
        do {
            try change(database)
        } catch {
            lastError = "Could not save locally: \(error.localizedDescription)"
            return
        }
        requestSync()
    }

    // MARK: - Observation

    private func startObserving() {
        guard let database else { return }
        observers.append(Task { [weak self] in
            do {
                for try await projects in database.observeProjects() {
                    self?.projects = projects
                }
            } catch {
                self?.lastError = "Could not read projects: \(error.localizedDescription)"
            }
        })
        observers.append(Task { [weak self] in
            do {
                for try await tasks in database.observeOpenTasks() {
                    self?.openTasks = tasks
                }
            } catch {
                self?.lastError = "Could not read tasks: \(error.localizedDescription)"
            }
        })
        observers.append(Task { [weak self] in
            do {
                for try await placements in database.observePlacements() {
                    self?.placementsByTask = Dictionary(grouping: placements, by: \.taskId)
                }
            } catch {
                self?.lastError = "Could not read the schedule: \(error.localizedDescription)"
            }
        })
        observers.append(Task { [weak self] in
            do {
                for try await accounts in database.observeAccounts() {
                    self?.accounts = accounts
                }
            } catch {
                self?.lastError = "Could not read accounts: \(error.localizedDescription)"
            }
        })
        observers.append(Task { [weak self] in
            do {
                for try await calendars in database.observeCalendars() {
                    self?.calendars = calendars
                }
            } catch {
                self?.lastError = "Could not read calendars: \(error.localizedDescription)"
            }
        })
        observers.append(Task { [weak self] in
            do {
                for try await count in database.observePendingWriteCount() {
                    self?.pendingWriteCount = count
                }
            } catch {
                self?.lastError = "Could not read pending writes: \(error.localizedDescription)"
            }
        })
        observeAgenda()
    }

    /// (Re)starts the agenda observation for `selectedDay`; the previous one is cancelled.
    private func observeAgenda() {
        agendaObserver?.cancel()
        guard let database else { return }
        let day = selectedDay
        let calendar = calendar
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
}
