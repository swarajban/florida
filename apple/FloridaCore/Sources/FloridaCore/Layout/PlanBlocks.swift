import Foundation

/// A block of the plan that is neither a task nor an event: a commitment the scheduler placed
/// from the routine (the gym) or time it holds for a project. Joined from store rows for display
/// by both apps; no I/O.
public struct PlanBlock: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// A `RoutineOccurrence` of the routine block with this id.
        case commitment(blockId: String)
        /// A `ProjectPlacement` of the project with this id.
        case project(projectId: String)
    }

    /// Unique among plan blocks, task placements and events: the row's id behind a kind prefix.
    public var id: String
    public var kind: Kind
    /// The routine block's or the project's name.
    public var title: String
    public var startAt: Date
    public var endAt: Date
    /// As `Placement.lane`; always nil for a commitment.
    public var lane: Int?

    public init(id: String, kind: Kind, title: String, startAt: Date, endAt: Date, lane: Int? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.lane = lane
    }

    public var isCommitment: Bool {
        if case .commitment = kind { return true }
        return false
    }

    public var minutes: Int { Int(endAt.timeIntervalSince(startAt) / 60) }

    /// Every occurrence and project block whose routine block or project is known, by start then
    /// id. Project time is only drawn for an active project: pausing one takes its time off the
    /// calendar at once instead of waiting for the server's next run.
    public static func join(
        occurrences: [RoutineOccurrence], projectPlacements: [ProjectPlacement],
        blocksById: [String: RoutineBlock], projectsById: [String: Project]
    ) -> [PlanBlock] {
        let commitments = occurrences.compactMap { occurrence -> PlanBlock? in
            guard let block = blocksById[occurrence.blockId], block.deletedAt == nil else { return nil }
            return PlanBlock(
                id: "commitment:\(occurrence.id)", kind: .commitment(blockId: block.id), title: block.name,
                startAt: occurrence.startAt, endAt: occurrence.endAt)
        }
        let projectTime = projectPlacements.compactMap { placement -> PlanBlock? in
            guard let project = projectsById[placement.projectId], project.deletedAt == nil, project.status == .active
            else { return nil }
            return PlanBlock(
                id: "project:\(placement.id)", kind: .project(projectId: project.id), title: project.name,
                startAt: placement.startAt, endAt: placement.endAt, lane: placement.lane)
        }
        return (commitments + projectTime).sorted { ($0.startAt, $0.id) < ($1.startAt, $1.id) }
    }
}

/// Which pieces of shared-attention work run side by side.
public enum ParallelWork {
    /// One laned block of the plan: a task placement or project time with a `lane`.
    public struct Span: Hashable, Sendable {
        public var id: String
        public var startAt: Date
        public var endAt: Date
        public var lane: Int

        public init(id: String, startAt: Date, endAt: Date, lane: Int) {
            self.id = id
            self.startAt = startAt
            self.endAt = endAt
            self.lane = lane
        }
    }

    /// For each span that overlaps a span in another lane, the ids of those spans by lane, then
    /// start, then id. A span alone in its time has no entry: work that could be shared but has
    /// nothing beside it reads as ordinary work.
    public static func companions(of spans: [Span]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for span in spans {
            let beside = spans
                .filter { $0.id != span.id && $0.lane != span.lane && $0.startAt < span.endAt && $0.endAt > span.startAt }
                .sorted { ($0.lane, $0.startAt, $0.id) < ($1.lane, $1.startAt, $1.id) }
            if !beside.isEmpty {
                result[span.id] = beside.map(\.id)
            }
        }
        return result
    }

    /// What to print beside each laned block: for every task placement (by `Placement.id`) and
    /// project block (by `PlanBlock.id`) that shares its time, the titles of the work in the other
    /// lanes, in `companions(of:)` order. Placements of tasks missing from `tasksById` (done or
    /// deleted) are left out on both sides.
    public static func companionTitles(
        placements: [Placement], tasksById: [String: TaskItem], planBlocks: [PlanBlock]
    ) -> [String: [String]] {
        var titles: [String: String] = [:]
        var spans: [Span] = []
        for placement in placements {
            guard let lane = placement.lane, let task = tasksById[placement.taskId] else { continue }
            titles[placement.id] = task.title
            spans.append(Span(id: placement.id, startAt: placement.startAt, endAt: placement.endAt, lane: lane))
        }
        for block in planBlocks {
            guard let lane = block.lane else { continue }
            titles[block.id] = block.title
            spans.append(Span(id: block.id, startAt: block.startAt, endAt: block.endAt, lane: lane))
        }
        return companions(of: spans).mapValues { ids in ids.compactMap { titles[$0] } }
    }
}

extension DayKind {
    /// What a date is: its live override, else what its weekday's planned routine blocks make it
    /// (an office day when one of them allows office work, a home day when any allows work, else
    /// off). `weekday` is Sunday = 0 … Saturday = 6, as in `RoutineBlock.days`.
    public static func of(date: String, weekday: Int, blocks: [RoutineBlock], overrides: [DayOverride]) -> DayKind {
        if let override = overrides.first(where: { $0.date == date && $0.deletedAt == nil }) {
            return override.kind
        }
        let planned = blocks.filter { $0.deletedAt == nil && !$0.optional && !$0.allows.isEmpty && $0.days.contains(weekday) }
        if planned.contains(where: { $0.allows.contains(.office) }) { return .office }
        return planned.isEmpty ? .off : .home
    }

    /// `of(date:weekday:blocks:overrides:)` for the local day of `calendar` containing `day`.
    public static func of(day: Date, calendar: Calendar, blocks: [RoutineBlock], overrides: [DayOverride]) -> DayKind {
        of(
            date: DayOverride.key(for: day, calendar: calendar), weekday: calendar.component(.weekday, from: day) - 1,
            blocks: blocks, overrides: overrides)
    }

    /// "Home day", "Office day", "Day off".
    public var label: String {
        switch self {
        case .home: "Home day"
        case .office: "Office day"
        case .off: "Day off"
        }
    }
}

extension DayOverride {
    /// The `date` key of the local day of `calendar` containing `day`: "YYYY-MM-DD".
    public static func key(for day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let pad = { (value: Int?, width: Int) -> String in
            let digits = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))"
    }
}

extension PlanSummary {
    /// Names of the commitments (the gym) that found no free slot in the week containing `day`,
    /// by name. Weeks start on Sunday, as the scheduler counts them, whatever `calendar` says.
    public func missedNames(inWeekOf day: Date, blocksById: [String: RoutineBlock], calendar: Calendar) -> [String] {
        let sinceSunday = calendar.component(.weekday, from: day) - 1
        guard let sunday = calendar.date(byAdding: .day, value: -sinceSunday, to: calendar.startOfDay(for: day)) else { return [] }
        let week = DayOverride.key(for: sunday, calendar: calendar)
        return missed
            .filter { $0.weekOf == week }
            .compactMap { blocksById[$0.blockId]?.name }
            .sorted()
    }

    /// The minutes still free on the local day containing `day`, per task context; nil outside
    /// the seven days the scheduler reports.
    public func freeMinutes(on day: Date, calendar: Calendar) -> DayCapacity.FreeMinutes? {
        let key = DayOverride.key(for: day, calendar: calendar)
        return capacity.first { $0.date == key }?.freeMinutes
    }
}

extension ProjectStatus {
    /// "Active", "Thinking about", "On hold", "Done".
    public var label: String {
        switch self {
        case .active: "Active"
        case .thinking: "Thinking about"
        case .onHold: "On hold"
        case .done: "Done"
        }
    }

    /// The order the projects list reads in, and the order a one-key status change cycles through.
    public static let listOrder: [ProjectStatus] = [.active, .thinking, .onHold, .done]

    /// The status after this one in `listOrder`, wrapping from done back to active.
    public var next: ProjectStatus {
        let order = Self.listOrder
        let index = order.firstIndex(of: self) ?? 0
        return order[(index + 1) % order.count]
    }
}

/// The projects of one status, for the projects list.
public struct ProjectSection: Hashable, Sendable, Identifiable {
    public var status: ProjectStatus
    /// By `sortOrder`, then name, then id. Never empty.
    public var projects: [Project]

    public var id: ProjectStatus { status }

    /// Live projects grouped by status in `ProjectStatus.listOrder`; a status without projects
    /// has no section.
    public static func sections(of projects: [Project]) -> [ProjectSection] {
        let live = projects.filter { $0.deletedAt == nil }
        return ProjectStatus.listOrder.compactMap { status in
            let matching = live
                .filter { $0.status == status }
                .sorted { ($0.sortOrder, $0.name.lowercased(), $0.id) < ($1.sortOrder, $1.name.lowercased(), $1.id) }
            return matching.isEmpty ? nil : ProjectSection(status: status, projects: matching)
        }
    }
}
