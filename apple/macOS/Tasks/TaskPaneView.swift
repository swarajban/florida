import AppKit
import FloridaKit
import SwiftUI

/// The right-hand task list: today's suggestions for optional routine blocks on top ("Evening, if
/// you're up for it"), then Inbox and open tasks grouped by due date or category. Keeps the
/// selected row scrolled into view as `j` / `k`
/// move it, and tells the model which rows are on screen, for jump mode.
struct TaskPaneView: View {
    @Environment(AppModel.self) private var model
    @State private var clickedItem: ItemID?

    private let opensTaskOnSingleClick = true

    static let width: CGFloat = 320
    /// About the height of a section header, which stays pinned over the top of the list once it
    /// has scrolled: a row under it is not on screen.
    static let pinnedHeaderHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tasks")
                    .font(.title3.weight(.medium))
                if model.focus == .tasks {
                    Circle()
                        .fill(FloridaStyle.ink)
                        .frame(width: 6, height: 6)
                }
                Spacer()
                Text("\(model.openTasks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Menu {
                    Picker("Group tasks", selection: Binding(
                        get: { model.taskListGrouping }, set: { model.taskListGrouping = $0 })) {
                        ForEach(TaskListGrouping.allCases, id: \.self) { grouping in
                            Text(grouping.title).tag(grouping)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Group by due date / category (g o)")
                .accessibilityLabel("Group tasks")
                .accessibilityValue(model.taskListGrouping.title)
                .accessibilityIdentifier("task-grouping-menu")
                Button {
                    model.perform(.newTask)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New task (C)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.paneSuggestions) { group in
                            Section {
                                ForEach(group.picks, id: \.paneItemID) { pick in
                                    suggestionRow(pick)
                                }
                                Text("Suggestions only: none of this is on the plan.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 2)
                                    .padding(.bottom, 8)
                            } header: {
                                OptionalPicksHeader(group: group)
                            }
                        }
                        ForEach(model.taskGroups) { group in
                            if group.tasks.isEmpty {
                                TaskGroupHeader(group: group)
                            } else {
                                Section {
                                    ForEach(group.tasks, id: \.paneItemID) { task in
                                        TaskPaneRow(taskID: task.id, isInbox: group.isInbox, onClick: handleRowClick)
                                    }
                                } header: {
                                    TaskGroupHeader(group: group)
                                }
                            }
                        }
                        if model.openTasks.isEmpty {
                            ContentUnavailableView(
                                "No open tasks", systemImage: "checkmark.circle",
                                description: Text("Press C to add one."))
                        }
                    }
                    .padding(.bottom, 8)
                    .animation(.easeOut(duration: 0.15), value: model.openTasks.map(\.id))
                }
                .accessibilityIdentifier("task-pane-scroll")
                .onChange(of: model.selection) { _, selection in
                    let clicked = clickedItem
                    clickedItem = nil
                    guard selection != clicked else { return }
                    if let selection, selection.isTask || selection.isSuggestion,
                       model.focus == .tasks || model.gridLayout.day(of: selection) == nil {
                        if !model.paneItemsOnScreen.contains(selection) {
                            proxy.scrollTo(selection, anchor: .center)
                        }
                    }
                }
                .onChange(of: model.taskListGrouping) {
                    if let selection = model.selection { proxy.scrollTo(selection, anchor: .center) }
                }
            }
        }
        .frame(width: Self.width)
        .background(FloridaStyle.panel)
    }

    private func suggestionRow(_ pick: OptionalPicks.Pick) -> some View {
        let item = ItemID.suggestion(pick.id)
        let takeTitle = RoutineText.takeTitle(pick.placement, now: model.clockNow, calendar: model.calendar)
        return OptionalPickRowView(
            pick: pick, category: model.categoriesById[pick.task.categoryId], takeTitle: takeTitle,
            isSelected: model.selection == item, isFocused: model.focus == .tasks,
            jumpLabel: model.jumpLabel(for: item)
        ) {
            model.take(pick)
        }
        // Its label sits in the middle of the row, whose height varies: the whole row has to show.
        .tracksJumpVisibility(of: item, labelStrip: nil, in: model)
        .contextMenu {
            Button(takeTitle) { model.take(pick) }
            Divider()
            TaskActionsMenu(task: pick.task)
        }
        .onClick { isDouble in
            handleRowClick(item, isDouble: isDouble)
        }
    }

    private func handleRowClick(_ item: ItemID, isDouble: Bool) {
        clickedItem = model.selection == item ? nil : item
        model.mainWindow?.makeFirstResponder(nil)
        model.select(item, in: .tasks)
        if isDouble || opensTaskOnSingleClick { model.editSelection() }
    }
}

private struct TaskPaneRow: View {
    @Environment(AppModel.self) private var model
    let taskID: String
    let isInbox: Bool
    let onClick: @MainActor (ItemID, Bool) -> Void

    var body: some View {
        if let task = model.tasksById[taskID], task.isOpen {
            content(task)
        }
    }

    private func content(_ task: TaskItem) -> some View {
        let item = ItemID.task(task.id)
        let suggestion = isInbox ? model.suggestedCategory(for: task) : nil
        let category = model.categoriesById[task.categoryId]
        let tint = category?.tint ?? .defaultCategory
        return TaskRowView(
            task: task, state: model.scheduleState(for: task),
            tint: tint, category: model.taskListGrouping == .dueDate && category?.isInbox == false ? category : nil,
            isSelected: model.selection == item, isFocused: model.focus == .tasks,
            isUntriaged: isInbox, suggestion: suggestion,
            jumpLabel: model.jumpLabel(for: item),
            calendar: model.taskListCalendar, now: model.clockNow,
            onComplete: { model.complete(task) }
        ) {
            if let suggestion { model.move(task, to: suggestion) }
        }
        .tracksJumpVisibility(of: item, labelStrip: TaskRowView.jumpLabelStrip, in: model)
        .transition(model.completingTaskIds.contains(task.id) ? .bloomFold(tint) : .opacity)
        .contextMenu {
            TaskActionsMenu(task: task)
        }
        .onClick { isDouble in
            onClick(item, isDouble)
        }
    }
}

private extension TaskItem {
    var paneItemID: ItemID { .task(id) }
}

private extension OptionalPicks.Pick {
    var paneItemID: ItemID { .suggestion(id) }
}

private extension View {
    /// Keeps `model.paneItemsOnScreen` right for this row of the task pane: `item` is in it while
    /// the row's jump label would be on screen, which is while `labelStrip` (measured down from
    /// the row's top; nil for the whole row) is clear of the pinned section header and of the
    /// pane's bottom edge. The geometry is read on every scrolled frame, but the model hears only
    /// when the answer changes.
    func tracksJumpVisibility(of item: ItemID, labelStrip: ClosedRange<CGFloat>?, in model: AppModel) -> some View {
        modifier(TaskPaneVisibility(item: item, labelStrip: labelStrip, model: model))
    }
}

private struct TaskPaneVisibility: ViewModifier {
    let item: ItemID
    let labelStrip: ClosedRange<CGFloat>?
    let model: AppModel
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        let header = TaskPaneView.pinnedHeaderHeight
        content.onGeometryChange(for: Bool.self) { proxy in
            guard let pane = proxy.bounds(of: .scrollView) else { return false }
            let row = proxy.frame(in: .scrollView)
            let strip = labelStrip ?? 0...row.height
            return JumpViewport(top: header, bottom: pane.height)
                .shows(top: row.minY + strip.lowerBound, bottom: row.minY + strip.upperBound)
        } action: { isOnScreen in
            model.paneVisibilityRegistrations.set(item, owner: owner, visible: isOnScreen)
        }
        .onDisappear {
            model.paneVisibilityRegistrations.set(item, owner: owner, visible: false)
        }
    }
}

/// A section's header: title and count. Inbox reads "3 to triage"; an empty category is
/// a dimmed collapsed line.
struct TaskGroupHeader: View {
    let group: TaskListSection

    var body: some View {
        let isEmpty = group.tasks.isEmpty
        HStack(spacing: 6) {
            if group.isInbox {
                Image(systemName: "tray")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let category = group.category {
                Circle()
                    .fill(category.tint)
                    .frame(width: 8, height: 8)
            } else {
                Image(systemName: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(group.title)
                .font(.subheadline.weight(isEmpty ? .regular : .semibold))
            if isEmpty {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if group.isInbox, !isEmpty {
                Text("\(group.tasks.count) to triage")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            } else {
                Text("\(group.tasks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(isEmpty ? Color.secondary : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, isEmpty ? 6 : 9)
        .background(FloridaStyle.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.title)
        .accessibilityIdentifier("task-section-\(group.id)")
    }
}
