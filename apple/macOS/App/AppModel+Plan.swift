import FloridaKit
import Foundation

// Projects, day kinds, the brief and "Why here?". Local-first like tasks: a project or a day's
// kind changes in the store at once, and the server's next scheduler run re-plans around it.

/// The answer to "Why here?" for one task: loading until `text` or `error` is set.
struct PlacementExplanation: Identifiable, Equatable {
    /// The task's id.
    var id: String
    /// The request this is the answer to: asking again about the same task is another one.
    let request = UUID()
    var title: String
    var text: String?
    var error: String?

    var isLoading: Bool { text == nil && error == nil }
}

extension AppModel {
    // MARK: Projects

    /// Live projects grouped by status, in the order the list reads.
    var projectSections: [ProjectSection] { ProjectSection.sections(of: projects) }

    func project(id: String?) -> Project? {
        id.flatMap { projectsById[$0] }
    }

    /// The project's open tasks, in the task pane's order.
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

    /// Creates or updates the project and syncs. False, with a status message, when the name is
    /// empty or the store refused.
    @discardableResult
    func save(project: Project, original: Project? = nil) -> Bool {
        guard let database else { return false }
        var project = project
        if original == nil || project.name != original?.name {
            project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !project.name.isEmpty else {
            statusMessage = "Give the project a name"
            return false
        }
        if original == nil || project.nextStep != original?.nextStep {
            project.nextStep = Self.trimmedOrNil(project.nextStep)
        }
        if original == nil || project.notes != original?.notes {
            project.notes = Self.trimmedOrNil(project.notes)
        }
        if original == nil || project.weeklyMinutes != original?.weeklyMinutes,
           let minutes = project.weeklyMinutes, minutes <= 0 {
            project.weeklyMinutes = nil
        }
        do {
            try database.saveProject(project, original: original)
        } catch {
            statusMessage = "Could not save the project: \(error.localizedDescription)"
            return false
        }
        scheduleSync()
        if original != project {
            pushUndo(UndoEntry(label: "Project changes", restores: [.unavailable], at: Date()))
        }
        return true
    }

    /// Only an active project's tasks are scheduled, so this is how a project is paused or resumed.
    func setStatus(_ status: ProjectStatus, of project: Project) {
        guard project.status != status else { return }
        let original = project
        var project = project
        project.status = status
        if save(project: project, original: original) {
            showGhost("\(project.name): \(status.label)")
        }
    }

    /// `s` in the projects overlay: the next status in the list's order.
    func cycleStatus(of project: Project) {
        setStatus(project.status.next, of: project)
    }

    /// Deletes the project; its tasks stay, without a project.
    func delete(project: Project) {
        guard let database else { return }
        do {
            try database.deleteProject(id: project.id)
        } catch {
            statusMessage = "Could not delete the project: \(error.localizedDescription)"
            return
        }
        pushUndo(UndoEntry(label: "Deleted project", restores: [.unavailable], at: Date()))
        showGhost("Deleted \(Self.quoted(project.name))")
        scheduleSync()
    }

    private static func trimmedOrNil(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: Day kinds

    /// What `day` is: its override, else what its weekday's routine makes it.
    func dayKind(of day: Date) -> DayKind {
        DayKind.of(day: day, calendar: calendar, blocks: routineBlocks, overrides: dayOverrides)
    }

    /// The override on `day`, when it differs from its weekday's routine.
    func dayOverride(on day: Date) -> DayOverride? {
        let key = DayOverride.key(for: day, calendar: calendar)
        return dayOverrides.first { $0.date == key && $0.deletedAt == nil }
    }

    /// Makes `day` a home, office or off day; the scheduler re-plans it on the next sync. An
    /// override already on the day keeps its note. Nothing is written when the routine already
    /// makes the day that kind.
    func setDay(_ day: Date, kind: DayKind) {
        guard availabilityShare == nil, let database else { return }
        let existing = dayOverride(on: day)
        guard existing != nil || dayKind(of: day) != kind else {
            statusMessage = "\(DateText.day(day, calendar: calendar)) is already \(kind.sentenceLabel)"
            return
        }
        do {
            try database.setDay(DayOverride.key(for: day, calendar: calendar), kind: kind, note: existing?.note)
        } catch {
            statusMessage = "Could not change the day: \(error.localizedDescription)"
            return
        }
        showGhost("\(DateText.day(day, calendar: calendar)) is \(kind.sentenceLabel)", for: .seconds(2))
        scheduleSync()
    }

    /// Puts `day` back on its weekday's routine.
    func clearDayOverride(on day: Date) {
        guard availabilityShare == nil, let database else { return }
        guard dayOverride(on: day) != nil else {
            statusMessage = "\(DateText.day(day, calendar: calendar)) already follows the routine"
            return
        }
        do {
            try database.clearDay(DayOverride.key(for: day, calendar: calendar))
        } catch {
            statusMessage = "Could not change the day: \(error.localizedDescription)"
            return
        }
        showGhost("\(DateText.day(day, calendar: calendar)) follows the routine again", for: .seconds(2))
        scheduleSync()
    }

    // MARK: The plan

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

    // MARK: Brief and explanations

    /// The latest daily brief the server wrote.
    var dailyBrief: Brief? { briefs.first { $0.kind == .daily } }
    /// The latest weekly review.
    var weeklyBrief: Brief? { briefs.first { $0.kind == .weekly } }

    /// Whether `brief` is for today (a daily brief) rather than an earlier day's left over. The
    /// server dates a daily brief in the routine's time zone (UTC without a settings row), where
    /// the date can differ from this Mac's, so today in either zone counts.
    func isCurrent(_ brief: Brief) -> Bool {
        if brief.kind == .weekly { return true }
        let now = Date()
        var routine = Calendar(identifier: .gregorian)
        routine.timeZone = TimeZone(identifier: userSettings?.timeZone ?? "UTC") ?? calendar.timeZone
        return brief.date == DayOverride.key(for: now, calendar: calendar)
            || brief.date == DayOverride.key(for: now, calendar: routine)
    }

    /// Has the server write the brief now from the current plan and stores it. A failure lands in
    /// `briefErrors` under `kind`, which the brief panel shows in place on that kind's tab.
    func writeBrief(_ kind: BriefKind) async {
        guard !briefsInFlight.contains(kind) else { return }
        guard let aiClient, let database else {
            briefErrors[kind] = "Connect to the server in Settings to get a brief."
            return
        }
        briefsInFlight.insert(kind)
        briefErrors[kind] = nil
        defer { briefsInFlight.remove(kind) }
        do {
            try database.storeBrief(try await aiClient.writeBrief(kind))
        } catch {
            briefErrors[kind] = Self.describeAI(error, doing: "write the brief")
        }
    }

    /// `y`: asks the server's model why the selected task is planned where it is. The answer
    /// arrives in `explanation`; the sheet shows a spinner until then.
    func explainSelection() {
        guard let task = selectedTask else {
            statusMessage = "Select a task first"
            return
        }
        guard let aiClient else {
            statusMessage = "Connect to the server in Settings to ask why"
            return
        }
        let asked = PlacementExplanation(id: task.id, title: task.title)
        explanation = asked
        Task { [weak self] in
            let result: Result<String, any Error>
            do {
                result = .success(try await aiClient.explainPlacement(taskId: task.id))
            } catch {
                result = .failure(error)
            }
            // Closed, or asked again (about this task or another) meanwhile: drop this answer.
            guard let self, self.explanation?.request == asked.request else { return }
            switch result {
            case .success(let text): self.explanation?.text = text
            case .failure(let error): self.explanation?.error = Self.describeAI(error, doing: "explain this")
            }
        }
    }

    private static func describeAI(_ error: any Error, doing what: String) -> String {
        switch error {
        case SyncError.http(503, _): "AI is off on the server (no Anthropic API key)."
        // The route answers 404 with `{error: "task … not found"}` for a task the server has not
        // received yet; a server without the route answers a bare 404.
        case SyncError.http(404, let body) where body.hasPrefix("task "):
            "The server does not have this task yet. Sync, then ask again."
        case SyncError.http(404, _): "The server needs an update before it can \(what)."
        default: "Could not \(what): \(describe(error))"
        }
    }
}
