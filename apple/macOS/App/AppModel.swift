import AppKit
import FloridaKit
import Observation

/// The macOS app's single source of truth, isolated to the main actor.
///
/// Everything the views draw comes from `AppDatabase` live queries (categories, open tasks,
/// placements, events in the loaded range, accounts, calendars, pending writes) or is UI state
/// kept here. Writes go to the store first and a background sync follows, so no view ever waits
/// on the network. Navigation, selection, commands, writes, sync, the palette and keyboard
/// handling live in the `AppModel+*.swift` extensions.
@Observable @MainActor
final class AppModel {
    // MARK: Dependencies

    private(set) var database: AppDatabase?
    var config: ServerConfig?
    var syncClient: SyncClient?
    /// Why the local store could not be opened; shown instead of the calendar.
    private(set) var startupError: String?
    let tokenStore: any TokenStore
    let calendar: Calendar

    // MARK: Store mirrors

    private(set) var categories: [TaskCategory] = []
    private(set) var openTasks: [TaskItem] = []
    private(set) var placements: [Placement] = []
    private(set) var events: [CalendarEvent] = []
    private(set) var accounts: [GoogleAccount] = []
    private(set) var calendars: [CalendarInfo] = []
    private(set) var pendingWriteCount = 0
    private(set) var tasksById: [String: TaskItem] = [:]
    private(set) var categoriesById: [String: TaskCategory] = [:]
    private(set) var calendarsById: [String: CalendarInfo] = [:]
    /// Each task's placements, by start.
    private(set) var placementsByTask: [String: [Placement]] = [:]

    // MARK: Navigation and selection

    var viewMode: CalendarViewMode = .week
    /// The date `DateNavigation.visibleRange` is built around.
    var anchorDate: Date
    /// The highlighted day and the cursor `h` / `l` move.
    var selectedDay: Date
    var selection: ItemID?
    var focus: Panel = .calendar
    var isTasksPaneVisible = true
    /// Frames for the visible days; rebuilt when data or the range changes and only read by the views.
    private(set) var gridLayout = GridLayout()
    /// Events are observed for this range: the visible range plus four weeks on each side.
    private(set) var loadedRange: Range<Date>?

    // MARK: Overlays and transient UI

    var isPaletteOpen = false
    var palette = PaletteState()
    var isHelpOpen = false
    /// The task open in the editor sheet; nil when the sheet is closed.
    var editorTask: TaskItem?
    var isGoToDateOpen = false
    /// Display form of a multi-key sequence in progress, e.g. "G".
    var pendingKeys = ""
    var statusMessage: String?

    // MARK: Sync status

    var lastSyncAt: Date?
    var lastSyncError: String?
    var syncsInFlight = 0
    var isSyncing: Bool { syncsInFlight > 0 }

    @ObservationIgnored var matcher = KeySequenceMatcher(keymap: .default)
    @ObservationIgnored var changeStream: ChangeStream?
    @ObservationIgnored var backgroundTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var eventsObserver: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false

    init(tokenStore: any TokenStore = KeychainTokenStore(), calendar: Calendar = .autoupdatingCurrent) {
        self.tokenStore = tokenStore
        self.calendar = calendar
        let today = calendar.startOfDay(for: Date())
        anchorDate = today
        selectedDay = today
    }

    // MARK: Lifecycle

    /// Opens the store, loads the saved server settings, and starts the live queries, the change
    /// stream and periodic sync. Safe to call more than once; the key monitor is installed by
    /// `KeyEventMonitorView` so it only sees the main window's events.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        do {
            let database = try AppDatabase(path: AppDatabase.defaultURL().path(percentEncoded: false))
            self.database = database
            startObserving(database)
            rangeDidChange()
        } catch {
            startupError = "Could not open the local store: \(error.localizedDescription)"
        }
        var saved: ServerConfig?
        do {
            saved = try tokenStore.load()
        } catch {
            lastSyncError = "Could not read the saved server settings: \(error.localizedDescription)"
        }
        applyConfig(saved)
    }

    // MARK: Range and layout

    /// Call after `viewMode` or `anchorDate` changed: widens the loaded range when the view left
    /// it and rebuilds the grid layout.
    func rangeDidChange() {
        let visible = visibleRange
        let covered = loadedRange.map { $0.lowerBound <= visible.lowerBound && visible.upperBound <= $0.upperBound } ?? false
        if !covered {
            // One line: a leading `..<` on a continuation line parses as the prefix operator.
            let lower = DateNavigation.shift(visible.lowerBound, by: -28, calendar: calendar)
            let upper = DateNavigation.shift(visible.upperBound, by: 28, calendar: calendar)
            loadedRange = lower..<upper
            restartEventsObserver()
        }
        rebuildLayout()
    }

    /// Recomputes every frame the calendar draws. Cheap (a few hundred items), so it runs on every
    /// data or navigation change rather than inside the drawing code.
    func rebuildLayout() {
        gridLayout = GridLayout.build(
            days: visibleDays, events: events, placements: placements, tasksById: tasksById,
            categoriesById: categoriesById, calendarsById: calendarsById, calendar: calendar)
    }

    // MARK: Live queries

    private func startObserving(_ database: AppDatabase) {
        observers = [
            observe(database.observeCategories()) { model, categories in
                model.categories = categories
                model.categoriesById = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                model.rebuildLayout()
            },
            observe(database.observeOpenTasks()) { model, tasks in
                model.openTasks = tasks
                model.tasksById = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                model.rebuildLayout()
            },
            observe(database.observePlacements()) { model, placements in
                model.placements = placements
                model.placementsByTask = Dictionary(grouping: placements, by: \.taskId)
                model.rebuildLayout()
            },
            observe(database.observeAccounts()) { model, accounts in
                model.accounts = accounts
            },
            observe(database.observeCalendars()) { model, calendars in
                model.calendars = calendars
                model.calendarsById = Dictionary(calendars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                model.rebuildLayout()
            },
            observe(database.observePendingWriteCount()) { model, count in
                model.pendingWriteCount = count
            },
        ]
    }

    private func restartEventsObserver() {
        eventsObserver?.cancel()
        guard let database, let range = loadedRange else { return }
        eventsObserver = observe(database.observeEvents(in: range)) { model, events in
            model.events = events
            model.rebuildLayout()
        }
    }

    /// Iterates a live query on the main actor and hands every value to `apply`.
    private func observe<S: AsyncSequence & Sendable>(
        _ sequence: S, _ apply: @escaping @MainActor @Sendable (AppModel, S.Element) -> Void
    ) -> Task<Void, Never> where S.Element: Sendable {
        Task { [weak self] in
            do {
                for try await value in sequence {
                    guard let self else { return }
                    apply(self, value)
                }
            } catch {
                self?.statusMessage = "Live query failed: \(error.localizedDescription)"
            }
        }
    }
}
