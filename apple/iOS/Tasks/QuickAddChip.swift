import FloridaKit
import SwiftUI

/// One parsed attribute shown under the quick-add field.
struct QuickAddChip: Identifiable, Hashable {
    let id: String
    let symbol: String
    let text: String
    var tint: Color = .secondary

    static func chips(for draft: QuickAddDraft, categories: [TaskCategory], calendar: Calendar) -> [QuickAddChip] {
        let now = Date()
        var chips: [QuickAddChip] = []
        if let minutes = draft.durationMinutes {
            chips.append(QuickAddChip(id: "duration", symbol: "clock", text: Formatting.duration(minutes: minutes)))
        }
        if let priority = draft.priority {
            chips.append(QuickAddChip(
                id: "priority", symbol: priority.symbolName, text: priority.displayName, tint: priority.tint))
        }
        if let context = draft.context {
            chips.append(QuickAddChip(id: "context", symbol: context.symbolName, text: context.displayName))
        }
        if let hint = draft.categoryHint {
            if let category = QuickAddTaskBuilder.matchCategory(hint: hint, in: categories) {
                chips.append(QuickAddChip(id: "category", symbol: "folder.fill", text: category.name, tint: Color.category(category)))
            } else {
                chips.append(QuickAddChip(id: "category", symbol: "questionmark.folder", text: "#\(hint) is new", tint: .orange))
            }
        }
        if let dueAt = draft.dueAt {
            let hard = draft.deadlineType == .hard
            chips.append(QuickAddChip(
                id: "due",
                symbol: hard ? "calendar.badge.clock" : "calendar",
                text: "\(hard ? "Due" : "By") \(Formatting.due(dueAt, now: now, calendar: calendar))",
                tint: hard ? .red : .secondary))
        }
        if let startAt = draft.startAt {
            chips.append(QuickAddChip(
                id: "start", symbol: "arrow.right.to.line",
                text: "After \(Formatting.notBefore(startAt, now: now, calendar: calendar))"))
        }
        if let pinnedStart = draft.pinnedStart {
            chips.append(QuickAddChip(
                id: "pinned", symbol: "pin.fill",
                text: "Pinned \(Formatting.dayAndTime(pinnedStart, now: now, calendar: calendar))"))
        }
        return chips
    }
}
