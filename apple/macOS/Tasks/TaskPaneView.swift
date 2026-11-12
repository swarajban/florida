import AppKit
import FloridaKit
import SwiftUI

/// The right-hand task list: today's suggestions for optional routine blocks on top ("Evening, if
/// you're up for it"), then Inbox (with its triage count) and each category's open tasks; empty
/// categories stay as one collapsed line. Keeps the selected row scrolled into view as `j` / `k`
/// move it, and tells the model which rows are on screen, for jump mode.
struct TaskPaneView: View {
    @Environment(AppModel.self) private var model
    @State private var clickedItem: ItemID?

    private let opensTaskOnSingleClick = false

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
                                ForEach(group.picks) { pick in
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
                                    ForEach(group.tasks) { task in
                                        row(task, in: group)
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
                .onChange(of: model.selection) { _, selection in
                    let clicked = clickedItem
                    clickedItem = nil
                    guard selection != clicked else { return }
                    if let selection, selection.isTask || selection.isSuggestion {
                        proxy.scrollTo(selection)
                    }
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
        .id(item)
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

    private func row(_ task: TaskItem, in group: CategoryTaskGroup) -> some View {
        let item = ItemID.task(task.id)
        let suggestion = group.isInbox ? model.suggestedCategory(for: task) : nil
        let tint = group.category?.tint ?? .defaultCategory
        return TaskRowView(
            task: task, state: model.scheduleState(for: task),
            tint: tint,
            isSelected: model.selection == item, isFocused: model.focus == .tasks,
            isUntriaged: group.isInbox, suggestion: suggestion,
            jumpLabel: model.jumpLabel(for: item),
            calendar: model.calendar,
            onComplete: { model.complete(task) }
        ) {
            if let suggestion { model.move(task, to: suggestion) }
        }
        .id(item)
        .tracksJumpVisibility(of: item, labelStrip: TaskRowView.jumpLabelStrip, in: model)
        .transition(model.completingTaskIds.contains(task.id) ? .bloomFold(tint) : .opacity)
        .contextMenu {
            TaskActionsMenu(task: task)
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

private extension View {
    /// Keeps `model.paneItemsOnScreen` right for this row of the task pane: `item` is in it while
    /// the row's jump label would be on screen, which is while `labelStrip` (measured down from
    /// the row's top; nil for the whole row) is clear of the pinned section header and of the
    /// pane's bottom edge. The geometry is read on every scrolled frame, but the model hears only
    /// when the answer changes.
    func tracksJumpVisibility(of item: ItemID, labelStrip: ClosedRange<CGFloat>?, in model: AppModel) -> some View {
        let header = TaskPaneView.pinnedHeaderHeight
        return onGeometryChange(for: Bool.self) { proxy in
            guard let pane = proxy.bounds(of: .scrollView) else { return false }
            let row = proxy.frame(in: .scrollView)
            let strip = labelStrip ?? 0...row.height
            return JumpViewport(top: header, bottom: pane.height)
                .shows(top: row.minY + strip.lowerBound, bottom: row.minY + strip.upperBound)
        } action: { isOnScreen in
            if isOnScreen {
                model.paneItemsOnScreen.insert(item)
            } else {
                model.paneItemsOnScreen.remove(item)
            }
        }
    }
}

/// A category's header: color, name and count. Inbox reads "3 to triage"; an empty category is
/// a dimmed collapsed line.
struct TaskGroupHeader: View {
    let group: CategoryTaskGroup

    var body: some View {
        let isEmpty = group.tasks.isEmpty
        HStack(spacing: 6) {
            if group.isInbox {
                Image(systemName: "tray")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(group.category?.tint ?? .defaultCategory)
                    .frame(width: 8, height: 8)
            }
            Text(group.name)
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
    }
}
