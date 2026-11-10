import FloridaKit
import Foundation

// Projects, day kinds and the brief. Local-first like tasks: a project or a day's kind changes in
// the store at once, and the server's next scheduler run re-plans around it.

extension AppModel {
    // MARK: - Projects

    /// Live projects grouped by status, in the order the list reads.
    var projectSections: [ProjectSection] { ProjectSection.sections(of: projects) }

    func project(id: String?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    /// The project's open tasks, in the task list's order.
    func openTasks(in project: Project) -> [TaskItem] {
        openTasks.filter { $0.projectId == project.id }
    }

    /// An unsaved active project after the existing ones, for the editor.
    func newProjectTemplate() -> Project {
        let now = Date()
        return Project(
            id: UUID().uuidString.lowercased(), name: "", status: .active,
            sortOrder: (projects.map(\.sortOrder).max() ?? 0) + 1, createdAt: now, updatedAt: now)
    }

    /// Creates or updates the project. Throws `LocalWriteError`.
    func saveProject(_ project: Project) throws {
        var project = project
        project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.name.isEmpty else { throw LocalWriteError("Give the project a name.") }
        project.nextStep = Self.trimmedOrNil(project.nextStep)
        project.notes = Self.trimmedOrNil(project.notes)
        if let minutes = project.weeklyMinutes, minutes <= 0 {
            project.weeklyMinutes = nil
        }
        try perform { try $0.saveProject(project) }
    }

    /// Only an active project's tasks are scheduled, so this is how a project is paused or resumed.
    func setStatus(_ status: ProjectStatus, of project: Project) {
        guard project.status != status else { return }
        var project = project
        project.status = status
        if write({ try $0.saveProject(project) }) {
            showToast(Toast(message: "\(project.name): \(status.label)", systemImage: status.symbolName, style: .info))
        }
    }

    /// Deletes the project; its tasks stay, without a project.
    func deleteProject(_ project: Project) {
        write { try $0.deleteProject(id: project.id) }
    }

    private static func trimmedOrNil(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Day kinds

    /// What `day` is: its override, else what its weekday's routine makes it.
    func dayKind(of day: Date) -> DayKind {
        DayKind.of(day: day, calendar: calendar, blocks: routineBlocks, overrides: dayOverrides)
    }

    /// The override on `day`, when it differs from its weekday's routine.
    func dayOverride(on day: Date) -> DayOverride? {
        let key = DayOverride.key(for: day, calendar: calendar)
        return dayOverrides.first { $0.date == key && $0.deletedAt == nil }
    }

    /// Makes `day` a home, office or off day; the scheduler re-plans it on the next sync.
    func setDay(_ day: Date, kind: DayKind) {
        let key = DayOverride.key(for: day, calendar: calendar)
        if write({ try $0.setDay(key, kind: kind) }) {
            showToast(Toast(message: "\(Self.dayName(day, calendar: calendar)) is \(kind.sentenceLabel)", systemImage: kind.symbolName, style: .info))
        }
    }

    /// Puts `day` back on its weekday's routine.
    func clearDayOverride(on day: Date) {
        let key = DayOverride.key(for: day, calendar: calendar)
        write { try $0.clearDay(key) }
    }

    private static func dayName(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide))
    }

    // MARK: - The plan

    /// Names of the commitments (the gym) with no free slot in the week of `day`.
    func missedCommitments(inWeekOf day: Date) -> [String] {
        planSummary.missedNames(
            inWeekOf: day, blocksById: Dictionary(routineBlocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            calendar: calendar)
    }

    /// Minutes still free on `day` per context; nil beyond the week the scheduler reports.
    func freeMinutes(on day: Date) -> DayCapacity.FreeMinutes? {
        planSummary.freeMinutes(on: day, calendar: calendar)
    }

    // MARK: - Brief and explanations

    /// The latest daily brief the server wrote.
    var dailyBrief: Brief? { briefs.first { $0.kind == .daily } }
    /// The latest weekly review.
    var weeklyBrief: Brief? { briefs.first { $0.kind == .weekly } }

    /// Whether `brief` is for today (a daily brief) rather than an earlier day's left over.
    func isCurrent(_ brief: Brief) -> Bool {
        brief.kind == .weekly || brief.date == DayOverride.key(for: Date(), calendar: calendar)
    }

    /// Has the server write the brief now from the current plan and stores it. Failures land in
    /// `briefError`, which the brief card shows in place.
    func writeBrief(_ kind: BriefKind) async {
        guard !briefsInFlight.contains(kind) else { return }
        guard let aiClient, let database else {
            briefError = "Connect to the server in Settings to get a brief."
            return
        }
        briefsInFlight.insert(kind)
        briefError = nil
        defer { briefsInFlight.remove(kind) }
        do {
            try database.storeBrief(try await aiClient.writeBrief(kind))
        } catch {
            briefError = Self.describeAI(error, doing: "write the brief")
        }
    }

    /// Why the task is planned where it is, in a sentence or two from the server's model.
    /// Throws `LocalWriteError` with a message to show in place.
    func explainPlacement(of task: TaskItem) async throws -> String {
        guard let aiClient else {
            throw LocalWriteError("Connect to the server in Settings to ask why.")
        }
        do {
            return try await aiClient.explainPlacement(taskId: task.id)
        } catch {
            throw LocalWriteError(Self.describeAI(error, doing: "explain this"))
        }
    }

    private static func describeAI(_ error: any Error, doing what: String) -> String {
        switch error {
        case SyncError.http(503, _): "AI is off on the server (no Anthropic API key)."
        case SyncError.http(404, _): "The server needs an update before it can \(what)."
        default: "Could not \(what): \(describe(error))"
        }
    }
}
