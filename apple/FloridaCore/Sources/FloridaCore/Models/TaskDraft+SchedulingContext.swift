extension TaskDraft {
    public func applyingSchedulingContext(to original: TaskItem, projects: [Project]) -> TaskItem {
        var task = original
        if let context { task.context = context }
        if let projectId, projects.contains(where: { $0.id == projectId && $0.deletedAt == nil }) {
            task.projectId = projectId
        }
        if let attention { task.attention = attention }
        return task
    }
}
