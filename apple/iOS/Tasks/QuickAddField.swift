import FloridaKit
import SwiftUI

/// The text field at the top of the Tasks tab. Parses the text with `QuickAddParser` on every
/// keystroke and shows what it understood as chips; return submits the draft.
struct QuickAddField: View {
    @Binding var text: String
    let categories: [TaskCategory]
    let calendar: Calendar
    let onSubmit: (QuickAddDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.secondary)
                TextField("Add a task, e.g. “Write report 2h by fri #work”", text: $text)
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .onSubmit(submit)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            if !text.isEmpty {
                let draft = QuickAddParser.parse(text, now: Date(), calendar: calendar)
                let chips = QuickAddChip.chips(for: draft, categories: categories, calendar: calendar)
                if !chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(chips) { chip in
                                Label(chip.text, systemImage: chip.symbol)
                                    .font(.caption)
                                    .foregroundStyle(chip.tint)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.fill.tertiary, in: Capsule())
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func submit() {
        let draft = QuickAddParser.parse(text, now: Date(), calendar: calendar)
        guard !draft.title.isEmpty else { return }
        onSubmit(draft)
        text = ""
    }
}

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
        if let hint = draft.categoryHint {
            if let category = QuickAddTaskBuilder.matchCategory(hint: hint, in: categories) {
                chips.append(QuickAddChip(id: "category", symbol: "folder.fill", text: category.name, tint: Color.category(category)))
            } else {
                chips.append(QuickAddChip(id: "category", symbol: "questionmark.folder", text: "#\(hint) → Inbox"))
            }
        }
        if let dueAt = draft.dueAt {
            let hard = draft.deadlineType == .hard
            chips.append(QuickAddChip(
                id: "due",
                symbol: hard ? "calendar.badge.exclamationmark" : "calendar",
                text: "\(hard ? "Due" : "By") \(Formatting.dayAndTime(dueAt, now: now, calendar: calendar))",
                tint: hard ? .red : .secondary))
        }
        if let startAt = draft.startAt {
            chips.append(QuickAddChip(
                id: "start", symbol: "arrow.right.to.line",
                text: "After \(Formatting.dayAndTime(startAt, now: now, calendar: calendar))"))
        }
        if let pinnedStart = draft.pinnedStart {
            chips.append(QuickAddChip(
                id: "pinned", symbol: "pin.fill",
                text: "Pinned \(Formatting.dayAndTime(pinnedStart, now: now, calendar: calendar))"))
        }
        return chips
    }
}
