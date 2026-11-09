import FloridaKit
import SwiftUI

/// Chips under the quick-add field showing what `QuickAddParser` understood and the defaults
/// that will fill the gaps, so the user sees the task before pressing Return. A `#hint` that
/// matches no category is called out (the task would land in Inbox) with ⇥ to create it.
struct QuickAddPreview: View {
    @Environment(AppModel.self) private var model
    let draft: QuickAddDraft
    let category: TaskCategory?
    /// The draft's `#hint` when no category matches it.
    let unknownHint: String?
    let calendar: Calendar

    private struct Chip: Identifiable {
        let id: String
        let symbol: String
        let text: String
        let isDefault: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.title.isEmpty {
                Text("Type a title; add 2h, !high, #category, by fri, at 3pm, after mon, // notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(draft.title)
                    .font(.headline)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    Label(chip.text, systemImage: chip.symbol)
                        .font(.caption)
                        .foregroundStyle(chip.isDefault ? Color.secondary : Color.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            chip.isDefault ? Color.primary.opacity(0.05) : Color.accentColor.opacity(0.15),
                            in: Capsule())
                }
            }
            if let unknownHint {
                Button {
                    model.createCategoryFromHint()
                } label: {
                    HStack(spacing: 6) {
                        Text("⇥")
                            .monospaced()
                            .padding(.horizontal, 5)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                        Text("Create category “\(AppModel.categoryName(fromHint: unknownHint))”")
                        Text("— otherwise it goes to \(category?.name ?? "Inbox")")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
            }
            if draft.title.count > 60 {
                Text("Long or pasted? ⌘↩ parses it with AI in the full editor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notes = draft.notes {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var chips: [Chip] {
        var chips: [Chip] = []
        chips.append(Chip(
            id: "duration", symbol: "clock",
            text: DateText.duration(minutes: draft.durationMinutes ?? AppModel.defaultDurationMinutes),
            isDefault: draft.durationMinutes == nil))
        chips.append(Chip(
            id: "priority", symbol: (draft.priority ?? .medium).symbolName,
            text: (draft.priority ?? .medium).displayName, isDefault: draft.priority == nil))
        if let unknownHint {
            chips.append(Chip(
                id: "category", symbol: "folder.badge.questionmark",
                text: "#\(unknownHint) → \(category?.name ?? "Inbox")", isDefault: true))
        } else if let category {
            chips.append(Chip(id: "category", symbol: "folder", text: category.name, isDefault: draft.categoryHint == nil))
        }
        if let dueAt = draft.dueAt {
            let kind = draft.deadlineType == .hard ? "Due" : "By"
            chips.append(Chip(
                id: "due", symbol: draft.deadlineType == .hard ? "flag.fill" : "flag",
                text: "\(kind) \(DateText.dayAndTime(dueAt, calendar: calendar))", isDefault: false))
        }
        if let startAt = draft.startAt {
            chips.append(Chip(
                id: "start", symbol: "arrow.right.to.line",
                text: "After \(DateText.day(startAt, calendar: calendar))", isDefault: false))
        }
        if let pinnedStart = draft.pinnedStart {
            chips.append(Chip(
                id: "pinned", symbol: "pin.fill",
                text: DateText.dayAndTime(pinnedStart, calendar: calendar), isDefault: false))
        }
        return chips
    }
}
