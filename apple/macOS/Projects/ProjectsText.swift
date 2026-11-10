/// Words the Projects sheet and the project editor share that `PlanText` does not have. They
/// read the same as the iOS projects list.
enum ProjectsText {
    /// The mark on a parallel project's row, and the editor's switch.
    static let parallel = "Parallel"

    /// "Next: Score the three new vendors": a project's next step under its name.
    static func next(_ step: String) -> String {
        "Next: \(step)"
    }

    /// "2h a week": the time held for a project each week.
    static func weekly(_ minutes: Int) -> String {
        "\(DateText.duration(minutes: minutes)) a week"
    }

    /// "3 open tasks", "1 open task", "No open tasks".
    static func openTasks(_ count: Int) -> String {
        switch count {
        case 0: "No open tasks"
        case 1: "1 open task"
        default: "\(count) open tasks"
        }
    }
}
