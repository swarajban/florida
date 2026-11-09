import FloridaKit
import Foundation
import Observation

/// The one object behind every screen. Opens the shared store, keeps in-memory copies of what the
/// views show (refreshed by GRDB observation in `AppModel+Observation`), applies local writes to
/// the store first (`AppModel+Writes`), and owns the `SyncClient` that pushes them and pulls server
/// changes in the background (`AppModel+Sync`).
///
/// Views only ever read the state below; nothing here awaits the network on their behalf.
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
    /// Category suggestions and task parsing; nil until there is a server config.
    @ObservationIgnored var aiClient: AIClient?
    let tokenStore = KeychainTokenStore()

    // MARK: Navigation

    /// The tab on screen. `RootView` binds the tab bar to it; deep links and the wordmark set it.
    var selectedTab: AppTab = LaunchOptions.initialTab ?? .agenda
    /// Bumped by `selectToday()`, so the agenda scrolls to now even when today was already showing.
    var todayRequests = 0

    // MARK: Observed store contents

    /// Local midnight of the day the Agenda tab shows.
    var selectedDay: Date
    var categories: [TaskCategory] = []
    var schedules: [Schedule] = []
    /// The weekly routine the scheduler places tasks in; read-only here.
    var routineBlocks: [RoutineBlock] = []
    /// The server's settings row (the routine's time zone); nil until the first sync.
    var userSettings: UserSettings?
    var openTasks: [TaskItem] = []
    /// Every scheduler placement, grouped by task; drives the "scheduled at" line of task rows.
    var placementsByTask: [String: [Placement]] = [:]
    /// The scheduler's unplaced remainders, by task id.
    var unscheduledByTask: [String: UnscheduledTask] = [:]
    /// The scheduler's suggestions for optional routine blocks (weekday evenings), by start.
    var optionalPlacements: [OptionalPlacement] = []
    /// Events and task blocks of `selectedDay`; nil until the first observation fires.
    var agenda: DayAgenda?
    var accounts: [GoogleAccount] = []
    var calendars: [CalendarInfo] = []
    /// Local writes not pushed yet, oldest first (`AppModel+Queue`).
    var pendingWrites: [PendingWrite] = []

    // MARK: Sync status

    /// Number of server calls in flight; `isSyncing` is derived from it.
    var activeOperations = 0
    var lastSyncAt: Date?
    /// Most recent sync failure, in words the user can act on; nil after a clean sync.
    var lastError: String?
    /// Writes the server refused, kept until dismissed in Settings.
    var rejectedChanges: [RejectedChange] = []
    @ObservationIgnored var runningSync: Task<Void, Never>?
    @ObservationIgnored var syncRequestedAgain = false
    @ObservationIgnored var periodicSync: Task<Void, Never>?
    @ObservationIgnored var changeStream: ChangeStream?
    @ObservationIgnored var changeListener: Task<Void, Never>?
    @ObservationIgnored var midnightWatcher: Task<Void, Never>?
    @ObservationIgnored var sceneIsActive = false
    /// The local day the agenda was last anchored to; see `AppModel+Today`.
    @ObservationIgnored var anchoredToday: Date

    // MARK: Feedback

    /// The toast at the bottom of the screen: undo after complete/delete, or a write failure.
    var toast: Toast?
    @ObservationIgnored var toastDismissal: Task<Void, Never>?
    /// Bumped on every completion; drives the one `.success` haptic.
    var completionCount = 0
    /// Tasks completed a moment ago, kept in the list (at their old position) while their row
    /// blooms in the category color and folds away; see `AppModel+Actions`.
    var blooming: [String: BloomingTask] = [:]
    /// Today's finished blocks, drawn as struck-through ghosts (`AppModel+Joy`).
    var ghostBlocks: [GhostBlock] = []

    // MARK: AI triage

    /// Category suggestions for Inbox tasks, by task id (`AppModel+Triage`).
    var triageSuggestions: [String: TriageSuggestion] = [:]
    /// Why suggestions are not coming, shown under Inbox; nil while they work.
    var triageUnavailable: String?
    /// (task, title) keys already asked, this launch and (answered ones) earlier; `AppModel+Triage`.
    @ObservationIgnored var triageAttempted: Set<String> = []
    @ObservationIgnored var triageRunner: Task<Void, Never>?

    @ObservationIgnored var observers: [Task<Void, Never>] = []
    @ObservationIgnored var agendaObserver: Task<Void, Never>?
    /// Events and task blocks of the days the hour grid shows (`AppModel+Grid`).
    var gridDays: [DayAgenda] = []
    @ObservationIgnored var gridObservation: GridObservation?

    var isSyncing: Bool { activeOperations > 0 }
    var needsSetup: Bool { serverConfig == nil }
    var pendingWriteCount: Int { pendingWrites.count }
    var today: Date { calendar.startOfDay(for: Date()) }

    init() {
        let calendar = Calendar.autoupdatingCurrent
        self.calendar = calendar
        let today = calendar.startOfDay(for: Date())
        selectedDay = today
        anchoredToday = today

        var openedDatabase: AppDatabase?
        var openError: String?
        do {
            openedDatabase = try Self.openStore()
        } catch {
            openError = "Could not open the local store: \(error.localizedDescription)"
        }
        database = openedDatabase
        storeError = openError
        ghostBlocks = GhostStore.load(today: today, calendar: calendar)
        triageAttempted = Self.loadTriageAttempts()

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

    /// Reads the server settings from the keychain and, when there are some, creates the clients.
    private func loadServerConfig() {
        do {
            serverConfig = try tokenStore.load()
        } catch {
            lastError = "Could not read the saved server settings: \(error.localizedDescription)"
        }
        if let serverConfig, let database {
            syncClient = SyncClient(database: database, config: serverConfig)
            aiClient = AIClient(config: serverConfig)
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

    /// Today, scrolled to now: the Today buttons, the wordmark, a widget tap. The agenda views
    /// watch `todayRequests` so the scroll happens even when today was already showing.
    func selectToday() {
        anchoredToday = today
        select(day: Date())
        todayRequests += 1
    }

    /// The wordmark on another tab: today's agenda.
    func showToday() {
        selectedTab = .agenda
        selectToday()
    }

    // MARK: - Lookups

    func category(id: String) -> TaskCategory? {
        categories.first { $0.id == id }
    }

    var inbox: TaskCategory? {
        categories.first(where: \.isInbox)
    }

    func calendarInfo(id: String) -> CalendarInfo? {
        calendars.first { $0.id == id }
    }

    func account(id: String) -> GoogleAccount? {
        accounts.first { $0.id == id }
    }

    func task(id: String) -> TaskItem? {
        openTasks.first { $0.id == id } ?? agenda?.placements.first { $0.task.id == id }?.task
    }
}

/// An AI category suggestion for an Inbox task, for the title it was made for; `categoryId` nil
/// means the model would leave the task in Inbox.
struct TriageSuggestion: Hashable {
    var title: String
    var categoryId: String?
    var rationale: String
}

/// A just-completed task still on screen for its bloom.
struct BloomingTask: Hashable {
    var task: TaskItem
    /// Its index in `openTasks` before it was completed.
    var index: Int
}

/// A write the server refused (4xx), copied out of `RejectedWrite` so the list outlives the next
/// push, which resets `SyncClient.lastRejectedWrites`.
struct RejectedChange: Identifiable, Hashable {
    var id: String
    var entity: PendingWrite.Entity
    var entityId: String
    var op: PendingWrite.Op
    var status: Int
    var message: String
    var at: Date
    /// Original task intent, including PATCH omissions and its revision precondition.
    var body: Data? = nil
}
