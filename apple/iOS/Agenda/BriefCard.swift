import FloridaKit
import SwiftUI

/// The daily brief at the top of today's agenda list: the headline and the first lines of what
/// the server's model wrote about today's plan (tap for the rest), a button that writes it again,
/// and the way to the weekly review. With no brief for today it is one quiet row offering to
/// write one. Progress shows on the write button and the daily brief's error
/// (`AppModel.briefErrors`) under the text.
struct BriefCard: View {
    /// Lines of the brief's body shown until the card is tapped, so the day's first items stay
    /// on screen.
    static let collapsedLines = 3

    @Environment(AppModel.self) private var model
    /// Opens the weekly review. The sheet belongs to the screen, not to a list row.
    let onShowWeek: () -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let brief {
                written(brief)
            } else {
                offer
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agenda-brief")
    }

    /// Today's brief. An earlier day's, left over, is not shown: the card offers to write today's.
    private var brief: Brief? {
        guard let brief = model.dailyBrief, model.isCurrent(brief) else { return nil }
        return brief
    }

    private func written(_ brief: Brief) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: BriefWriteButton.aiSymbol)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(brief.headline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(FloridaStyle.ink)
                            .lineLimit(isExpanded ? nil : 2)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                    Text(brief.body)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : Self.collapsedLines)
                }
                .multilineTextAlignment(.leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Shows less" : "Shows the whole brief")
            .accessibilityIdentifier("agenda-brief-text")
            if let error = model.briefErrors[.daily] {
                BriefErrorLine(message: error)
                    .padding(.top, 4)
                    .accessibilityIdentifier("agenda-brief-error")
            }
            HStack(spacing: 16) {
                BriefWriteButton(kind: .daily, title: "Rewrite")
                    .accessibilityIdentifier("agenda-brief-write")
                Spacer(minLength: 0)
                weekButton
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(FloridaStyle.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(FloridaStyle.rule)
        }
    }

    /// No brief for today yet: one line, as quiet as a free gap.
    private var offer: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 16) {
                BriefWriteButton(kind: .daily, title: "Write today's brief", symbol: BriefWriteButton.aiSymbol)
                    .accessibilityIdentifier("agenda-brief-write")
                Spacer(minLength: 0)
                weekButton
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            if let error = model.briefErrors[.daily] {
                BriefErrorLine(message: error)
                    .accessibilityIdentifier("agenda-brief-error")
            }
        }
    }

    private var weekButton: some View {
        Button(action: onShowWeek) {
            HStack(spacing: 3) {
                Text("Weekly review")
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .accessibilityHint("Shows the review of this week")
        .accessibilityIdentifier("agenda-brief-week")
    }
}

/// Has the server's model write the brief of `kind` now, with a spinner in place of the symbol
/// while it does. The caller picks the button style and the accessibility identifier.
struct BriefWriteButton: View {
    /// The app's mark for what the model wrote or will write, as on "Parse with AI".
    static let aiSymbol = "sparkles"

    @Environment(AppModel.self) private var model
    let kind: BriefKind
    let title: String
    var symbol = "arrow.clockwise"

    var body: some View {
        let isWriting = model.briefsInFlight.contains(kind)
        Button {
            Task {
                await model.writeBrief(kind)
            }
        } label: {
            HStack(spacing: 6) {
                if isWriting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .accessibilityHidden(true)
                }
                Text(isWriting ? "Writing…" : title)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .disabled(isWriting)
    }
}

/// Why the last brief request failed, where the brief would be.
struct BriefErrorLine: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.red)
    }
}

/// The week's review from the server's model, one tap from the brief card: all of it, when it
/// was written, and a button that writes it again.
struct WeeklyReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let brief = model.weeklyBrief {
                        Text(brief.headline)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(FloridaStyle.ink)
                        Text(brief.body)
                            .font(.body)
                        Text("Written \(Formatting.dayAndTime(brief.createdAt, now: Date(), calendar: model.calendar))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No review of this week yet.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    if let error = model.briefErrors[.weekly] {
                        BriefErrorLine(message: error)
                            .accessibilityIdentifier("weekly-review-error")
                    }
                    BriefWriteButton(
                        kind: .weekly, title: model.weeklyBrief == nil ? "Write this week's review" : "Rewrite",
                        symbol: model.weeklyBrief == nil ? BriefWriteButton.aiSymbol : "arrow.clockwise")
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("weekly-review-write")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("weekly-review")
            }
            .navigationTitle("Weekly Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(FloridaStyle.paper)
    }
}
