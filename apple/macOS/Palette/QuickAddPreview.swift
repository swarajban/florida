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
                Text("Type a title, then add details with the symbols below")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(draft.title)
                    .font(.headline)
                    .lineLimit(2)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { previewChips }
                    .fixedSize(horizontal: true, vertical: false)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                    previewChips
                }
            }
            if let source = draft.source {
                HStack(spacing: 6) {
                    Label(source.title, systemImage: source.symbolName)
                        .lineLimit(1)
                    Button {
                        model.palette.removeSource()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove source")
                    .accessibilityIdentifier("quick-add-remove-source")
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(FloridaStyle.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("quick-add-source")
            }
            Text("^due · !priority · #category · @context · *repeat · =estimate · ~start · //notes")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("smart-add-symbol-guide")
            DisclosureGroup("Smart Add examples and priority levels") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("^due: ^fri, ^nov 20, ^none (no due date)")
                    Text("!priority: !1 ASAP · !2 high · !3 medium · !4 low")
                    Text("#category: #work-engineering")
                    Text("@context: @computer, @errand, @home, @office — not a location")
                    Text("*repeat: *weekly, *every 2 weeks, *mon wed")
                    Text("=estimate: =45m, =2h")
                    Text("~start: ~tomorrow, ~nov 20")
                    Text("//notes: everything after // stays in the notes")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if model.palette.completedCategoryId != nil, category == nil {
                Text("The chosen category was deleted. Edit its #category or choose a current suggestion.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("smart-add-deleted-category")
            } else if let unknownHint {
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

    private var previewChips: some View {
        ForEach(chips) { chip in
            Label(chip.text, systemImage: chip.symbol)
                .font(.caption)
                .foregroundStyle(chip.isDefault ? Color.secondary : Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    chip.isDefault ? FloridaStyle.panel : FloridaStyle.ink.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 4))
                .accessibilityIdentifier("smart-add-preview-\(chip.id)")
        }
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
        if let context = draft.context {
            chips.append(Chip(id: "context", symbol: context.symbolName, text: context.displayName, isDefault: false))
        }
        if draft.dueDateNotNeeded {
            chips.append(Chip(id: "due", symbol: "calendar.badge.minus", text: "No due date", isDefault: false))
        } else if let dueAt = draft.dueAt {
            let kind = draft.deadlineType == .hard ? "Due" : "By"
            chips.append(Chip(
                id: "due", symbol: draft.deadlineType == .hard ? "calendar.badge.clock" : "calendar",
                text: "\(kind) \(DateText.due(dueAt, calendar: calendar))", isDefault: false))
        }
        if let recurrence = draft.recurrence {
            chips.append(Chip(id: "recurrence", symbol: "repeat", text: recurrence.summary, isDefault: false))
        }
        if let startAt = draft.startAt {
            chips.append(Chip(
                id: "start", symbol: "arrow.right.to.line",
                text: "After \(DateText.notBefore(startAt, calendar: calendar))", isDefault: false))
        }
        if let pinnedStart = draft.pinnedStart {
            chips.append(Chip(
                id: "pinned", symbol: "pin.fill",
                text: DateText.dayAndTime(pinnedStart, calendar: calendar), isDefault: false))
        }
        return chips
    }
}
