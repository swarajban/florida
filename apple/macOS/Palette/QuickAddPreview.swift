import FloridaKit
import SwiftUI

/// Chips under the quick-add field showing what `QuickAddParser` understood and the defaults
/// that will fill the gaps, so the user sees the task before pressing Return.
struct QuickAddPreview: View {
    let draft: QuickAddDraft
    let project: Project?
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
                Text("Type a title; add 2h, !high, #project, by fri, at 3pm, after mon, // notes")
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
        if let project {
            chips.append(Chip(id: "project", symbol: "folder", text: project.name, isDefault: draft.projectHint == nil))
        } else if let hint = draft.projectHint {
            chips.append(Chip(id: "project", symbol: "folder.badge.questionmark", text: "#\(hint)", isDefault: false))
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
