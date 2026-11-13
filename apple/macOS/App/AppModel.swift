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
    private static var taskListDefaults: UserDefaults {
        UserDefaults(suiteName: Florida.appGroup) ?? .standard
    }

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
    private(set) var blockingAllDayEvents: [CalendarEvent] = []
    private(set) var accounts: [GoogleAccount] = []
    private(set) var calendars: [CalendarInfo] = []
    private(set) var pendingWriteCount = 0
    private(set) var tasksById: [String: TaskItem] = [:]
    private(set) var categoriesById: [String: TaskCategory] = [:]
    private(set) var calendarsById: [String: CalendarInfo] = [:]
    /// Each task's placements, by start.
    private(set) var placementsByTask: [String: [Placement]] = [:]
    /// Why the scheduler could not place (all of) a task, by task id.
    private(set) var unscheduledByTask: [String: UnscheduledTask] = [:]
    /// The scheduler's suggestions for optional routine blocks (weekday evenings), by start.
    private(set) var optionalPlacements: [OptionalPlacement] = []
    private(set) var schedules: [Schedule] = []
    /// The weekly routine the scheduler places tasks in; read-only here.
    private(set) var routineBlocks: [RoutineBlock] = []
    /// The server's settings row (the routine's time zone); nil until the first sync.
    private(set) var userSettings: UserSettings?
    /// Ongoing projects of every status, by `sortOrder` then name (`AppModel+Plan`).
    private(set) var projects: [Project] = []
    private(set) var projectsById: [String: Project] = [:]
    /// Dates that differ from their weekday's routine: home, office or off.
    private(set) var dayOverrides: [DayOverride] = []
    private(set) var projectPlacements: [ProjectPlacement] = []
    private(set) var routineOccurrences: [RoutineOccurrence] = []
    /// The commitments (the gym) and time held for active projects, joined for the grid, by start.
    private(set) var planBlocks: [PlanBlock] = []
    /// Commitments with no slot and each day's free time, from the scheduler's last run.
    private(set) var planSummary = PlanSummary()
    /// The latest daily brief and weekly review, newest first.
    private(set) var briefs: [Brief] = []
    /// The briefs the server is writing right now.
    var briefsInFlight: Set<BriefKind> = []
    /// Why the last request for each kind of brief failed; the brief panel shows it on that kind's tab.
    var briefErrors: [BriefKind: String] = [:]
    /// Today's events and task blocks for the menu bar, observed for the current day.
    var todayAgenda: DayAgenda?
    /// The current minute; the menu bar title and agenda recompute from it.
    var clockNow = Date()
    /// The time grid's gutter labels in the system's 12/24-hour form, built once and again when
    /// the locale changes: the canvas must not format dates per frame.
    private(set) var hourLabels: [(minute: Int, label: String)]

    // MARK: Navigation and selection

    var viewMode: CalendarViewMode = .week
    /// The date `DateNavigation.visibleRange` is built around.
    var anchorDate: Date
    /// The highlighted day and the cursor `h` / `l` move.
    var selectedDay: Date
    var selection: ItemID?
    var focus: Panel = .calendar
    var isTasksPaneVisible = true
    var taskListGrouping = TaskListGrouping(
        rawValue: AppModel.taskListDefaults.string(forKey: "taskListGrouping") ?? "") ?? .dueDate {
        didSet {
            Self.taskListDefaults.set(taskListGrouping.rawValue, forKey: "taskListGrouping")
            endJump()
        }
    }
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
    /// Recurring deletes always explain the series-wide effect, including keyboard deletes.
    var recurringTaskToDelete: TaskItem?
    /// Text the new-task editor should send to the AI parser when it opens (quick add's ⌘↩).
    var editorAIText: String?
    /// The event whose detail popover is open.
    var eventDetailID: String? {
        didSet {
            eventResourceKeys = nil
            eventDetailIndicatorDay = nil
        }
    }
    var eventResourceKeys: JumpLabels<String>?
    var eventDetailIndicatorDay: Date?
    /// The event open in the editor sheet (a stored one, or the draft of a new one).
    var eventEditor: EventEditorRequest?
    /// The event whose delete is waiting for confirmation: nothing undoes an event delete.
    var eventToDelete: CalendarEvent?
    /// The event being dragged in the time grid, or just dropped and not yet in the layout.
    var gridDrag: GridDrag?
    /// A dropped event with guests, waiting for a yes: Google emails them the new time.
    var eventMove: EventMoveRequest?
    var isGoToDateOpen = false
    /// Display form of a multi-key sequence in progress, e.g. "g …".
    var pendingKeys = ""
    /// Jump mode (`f`): the labels on screen, narrowed by the keys typed so far; nil when off.
    var jump: JumpLabels<ItemID>?
    /// The stretch of the time grid that was on screen when the labels went up, so a block cut
    /// off at the top carries its label where it comes into view. Read only while `jump` is set.
    var jumpGridViewport: JumpViewport?
    /// The part of the 24-hour time grid on screen, in grid coordinates; `CalendarGridView` keeps
    /// it as the grid scrolls. Not observed: it changes on every scrolled frame, and nothing is
    /// drawn from it.
    @ObservationIgnored var gridVisibleRect = CGRect.zero
    /// Where the top of the time grid will be once the animated scroll now running ends; nil at
    /// rest. `f` pressed right after a key that scrolls labels what the scroll is about to show.
    @ObservationIgnored var gridScrollTarget: CGFloat?
    /// The task-pane rows whose jump label would be on screen; each row keeps its own entry
    /// (`tracksJumpVisibility`). Not observed, for the same reason.
    @ObservationIgnored var paneItemsOnScreen: Set<ItemID> = []
    var statusMessage: String?
    var availabilityShare: AvailabilityShareState?
    var isAvailabilityZoneOpen = false
    @ObservationIgnored var availabilityEventsObserver: Task<Void, Never>?
    var ghost: Ghost?
    /// Writes `z` can revert, oldest first.
    var undoStack: [UndoEntry] = []
    /// Set for a moment after a scheduler run moved visible task blocks, so they slide.
    var layoutTransition: LayoutTransition?
    /// What `.` repeats.
    var lastAction: RepeatableAction?
    /// The Done for now sheet, when open.
    var doneForNow: DoneForNowRequest?
    /// Tasks just completed, whose rows leave with the bloom instead of a plain fade.
    var completingTaskIds: Set<String> = []
    /// Bumped to ask the time grid to scroll; the grid owns its scroll position.
    var gridScrollRequest: GridScrollRequest?
    var isNewCategoryOpen = false
    /// The projects overlay (`g p`).
    var isProjectsOpen = false
    /// The project open in the editor sheet (a stored one, or the draft of a new one).
    var projectEditor: Project?
    /// The brief and weekly review panel (`g b`).
    var isBriefOpen = false
    /// The answer to "Why here?" for one task, while its sheet is open.
    var explanation: PlacementExplanation?
    /// The Settings tab to show, and a counter `RootView` watches to open the Settings window.
    var settingsTab: SettingsTab = .server
    var settingsRequest = 0

    // MARK: AI triage

    /// The server's category guesses for Inbox tasks, by task id.
    var aiSuggestions: [String: CategorySuggestion] = [:]
    @ObservationIgnored var aiClient: AIClient?
    /// The title each suggestion was requested for, so an edited title asks again.
    @ObservationIgnored var suggestionRequests: [String: String] = [:]
    @ObservationIgnored var suggestionWorker: Task<Void, Never>?
    /// Set for the session when the server has no AI configured (503) or rejects the token.
    @ObservationIgnored var isAIUnavailable = false

    // MARK: Sync status

    var lastSyncAt: Date?
    var lastSyncError: String?
    var syncsInFlight = 0
    var isSyncing: Bool { syncsInFlight > 0 }
    #if DEBUG
    var editorDiagnostics: EditorDiagnostics?
    #endif

    @ObservationIgnored var matcher = MacKeySequenceMatcher(keymap: .default)
    @ObservationIgnored var changeStream: ChangeStream?
    @ObservationIgnored var backgroundTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var eventsObserver: Task<Void, Never>?
    @ObservationIgnored private var blockingEventsObserver: Task<Void, Never>?
    @ObservationIgnored var agendaObserver: Task<Void, Never>?
    @ObservationIgnored var clockTask: Task<Void, Never>?
    @ObservationIgnored private var localeObserver: (any NSObjectProtocol)?
    /// The main window, so the menu bar can bring it back instead of opening another.
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored private var isStarted = false

    init(tokenStore: any TokenStore = KeychainTokenStore(), calendar: Calendar = .autoupdatingCurrent) {
        self.tokenStore = tokenStore
        self.calendar = calendar
        let today = calendar.startOfDay(for: Date())
        anchorDate = today
        selectedDay = today
        hourLabels = DateText.hourLabels(calendar: calendar)
    }

    // MARK: Lifecycle

    /// Opens the store, loads the saved server settings, and starts the live queries, the change
    /// stream and periodic sync. Safe to call more than once; the key monitor is installed by
    /// `KeyEventMonitorView` so it only sees the main window's events.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        observeLocale()
        #if DEBUG
        // Native UI checks use the same disposable fixture as iOS. No keychain, disk store,
        // AI client or sync client is opened, even if seeding the test store fails.
        if UserDefaults.standard.bool(forKey: "demoData") {
            do {
                let database = try AppDatabase.inMemory()
                let now = DemoData.fixedNow ?? Date()
                clockNow = now
                anchorDate = calendar.startOfDay(for: now)
                selectedDay = anchorDate
                try database.apply(DemoData.syncResponse(now: now, calendar: calendar))
                self.database = database
                try installEditorDiagnosticsIfNeeded()
                config = ServerConfig(token: "demo")
                viewMode = .threeDays
                startObserving(database)
                rangeDidChange()
                startClock()
            } catch {
                startupError = "Could not open the demo store: \(error.localizedDescription)"
            }
            return
        }
        #endif
        do {
            let database = try AppDatabase(path: AppDatabase.defaultURL().path(percentEncoded: false))
            self.database = database
            startObserving(database)
            rangeDidChange()
            startClock()
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

    /// Rebuilds the gutter labels when the locale changes, which includes the 12/24-hour setting.
    /// The block runs on the main queue, so the hop onto the main actor is only asserted.
    private func observeLocale() {
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hourLabels = DateText.hourLabels(calendar: self.calendar)
            }
        }
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
            days: visibleDays, events: events, placements: placements,
            // A month cell has no room for work that is not on the plan.
            suggestions: viewMode == .month ? [] : visibleDays.flatMap { optionalPicks(on: $0).flatMap(\.picks) },
            // The gym is a fixed part of a day; held project time is detail a month cell can skip.
            planBlocks: viewMode == .month ? planBlocks.filter(\.isCommitment) : planBlocks, projectsById: projectsById,
            tasksById: tasksById,
            categoriesById: categoriesById, calendarsById: calendarsById, schedules: activeSchedules,
            options: layoutOptions, lineLimit: viewMode == .month ? MonthGridView.maxLinesPerCell : nil,
            now: Date(), calendar: calendar,
            reservedLinesByDay: viewMode == .month ? Dictionary(uniqueKeysWithValues: visibleDays.map {
                ($0, AllDayBlocking.events(on: $0, from: blockingAllDayEvents, calendar: calendar).count)
            }) : [:])
        // A dropped event has arrived in its new slot: the drag's stand-in is no longer needed.
        if let drag = gridDrag, drag.isDropped, eventMove == nil,
           !gridLayout.blocksByDay.joined().contains(where: drag.applies) {
            gridDrag = nil
        }
        refreshAvailability()
    }

    /// Joins the gym's occurrences and project time with their names, then lays the grid out again.
    private func rebuildPlanBlocks() {
        planBlocks = PlanBlock.join(
            occurrences: routineOccurrences, projectPlacements: projectPlacements,
            blocksById: Dictionary(routineBlocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            projectsById: projectsById)
        rebuildLayout()
    }

    // MARK: Live queries

    private func startObserving(_ database: AppDatabase) {
        observers = [
            observe(database.observeCategories()) { model, categories in
                model.categories = categories
                model.categoriesById = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                model.rebuildLayout()
                model.refreshSuggestions()
            },
            observe(database.observeTasks()) { model, tasks in
                model.openTasks = tasks.filter(\.isOpen)
                model.tasksById = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                #if DEBUG
                model.refreshEditorDiagnostics()
                #endif
                model.rebuildLayout()
                model.refreshSuggestions()
            },
            observe(database.observeSchedules()) { model, schedules in
                model.schedules = schedules
                model.rebuildLayout()
            },
            observe(database.observeRoutineBlocks()) { model, blocks in
                model.routineBlocks = blocks
                model.rebuildPlanBlocks()
            },
            observe(database.observeProjects()) { model, projects in
                model.projects = projects
                model.projectsById = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                model.rebuildPlanBlocks()
            },
            observe(database.observeProjectPlacements()) { model, placements in
                model.projectPlacements = placements
                model.rebuildPlanBlocks()
            },
            observe(database.observeRoutineOccurrences()) { model, occurrences in
                model.routineOccurrences = occurrences
                model.rebuildPlanBlocks()
            },
            observe(database.observeDayOverrides()) { model, overrides in
                model.dayOverrides = overrides
            },
            observe(database.observePlanSummary()) { model, summary in
                model.planSummary = summary
            },
            observe(database.observeBriefs()) { model, briefs in
                model.briefs = briefs
            },
            observe(database.observeOptionalPlacements()) { model, suggestions in
                model.optionalPlacements = suggestions
                model.rebuildLayout()
            },
            observe(database.observeUserSettings()) { model, settings in
                model.userSettings = settings
            },
            observe(database.observePlacements()) { model, placements in
                let before = model.gridLayout.slotFrames
                model.placements = placements
                model.placementsByTask = Dictionary(grouping: placements, by: \.taskId)
                model.rebuildLayout()
                model.placementsDidChange(from: before)
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
            observe(database.observeUnscheduled()) { model, unscheduled in
                model.unscheduledByTask = Dictionary(unscheduled.map { ($0.taskId, $0) }, uniquingKeysWith: { first, _ in first })
            },
        ]
    }

    /// The first value is read synchronously, so a jump outside the loaded range draws its events
    /// in the same frame as the new columns rather than a run loop later; the observation then
    /// keeps them current.
    private func restartEventsObserver() {
        eventsObserver?.cancel()
        blockingEventsObserver?.cancel()
        guard let database, let range = loadedRange else { return }
        if let current = try? database.events(in: range) {
            events = current
        }
        eventsObserver = observe(database.observeEvents(in: range)) { model, events in
            model.events = events
            model.rebuildLayout()
        }
        if let current = try? database.blockingAllDayEvents(in: range, calendar: calendar) {
            blockingAllDayEvents = current
        }
        blockingEventsObserver = observe(database.observeBlockingAllDayEvents(in: range, calendar: calendar)) { model, events in
            model.blockingAllDayEvents = events
            if model.viewMode == .month { model.rebuildLayout() }
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
