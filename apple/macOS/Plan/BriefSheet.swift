import FloridaKit
import SwiftUI

/// The `g b` sheet: today's brief or the weekly review as the server's model wrote it, above the
/// plan facts for today (the day's kind, its free time, a commitment with no slot this week).
///
/// Everything works from the keyboard: `1` / `2` or ⇥ switch between today and the week, `r`
/// writes or rewrites the one shown, ↩ or Esc closes. A sheet is its own window, which the app's
/// key monitor does not watch, so the keys are handled here.
struct BriefSheet: View {
    @Environment(AppModel.self) private var model
    @State private var kind: BriefKind = .daily
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                reading
            }
            .scrollBounceBehavior(.basedOnSize)
            // Room for a brief of four wrapped lines, so switching between today and the week
            // rarely resizes the sheet; it grows for a longer one and scrolls only past the maximum.
            .frame(minHeight: 280, maxHeight: 460)
            Divider()
            facts
            Divider()
            footer
        }
        .frame(width: 560)
        // The sheet itself holds focus so key presses arrive here, wherever the pointer last clicked.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: .down) { press in
            handle(press)
        }
        .onAppear {
            isFocused = true
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Brief", selection: $kind) {
                Text("Today").tag(BriefKind.daily)
                Text("This week").tag(BriefKind.weekly)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("brief-kind")
            Spacer()
            if isWriting {
                ProgressView()
                    .controlSize(.small)
            }
            Button(writeTitle) {
                write()
            }
            .keyboardShortcut("r", modifiers: [])
            .disabled(isWriting)
            .accessibilityIdentifier("brief-write")
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    /// The brief shown, or what to do about not having one. About 70 characters to a line.
    private var reading: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.briefErrors[kind] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("brief-error")
            }
            if let brief {
                if !model.isCurrent(brief) {
                    Text("\(staleNote(brief)) Press R to write today's.")
                        .foregroundStyle(.secondary)
                }
                Text(brief.headline)
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("brief-headline")
                Text(Self.paragraphs(brief.body))
                    .font(.title3)
                    .lineSpacing(4)
                    .accessibilityIdentifier("brief-body")
            } else {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    /// What the plan itself says about today, whichever brief is shown.
    private var facts: some View {
        let today = Date()
        let dayKind = model.dayKind(of: today)
        // Free time is counted per task context; `PlanText.free` words the computer's.
        let free = model.freeMinutes(on: today).flatMap { PlanText.free($0.computer) }
        let missed = model.missedCommitments(inWeekOf: today)
        return VStack(alignment: .leading, spacing: 6) {
            fact("Today is \(dayKind.sentenceLabel)", symbol: dayKind.symbolName)
            if let free {
                fact(free, symbol: TaskContext.computer.symbolName)
            }
            if !missed.isEmpty {
                fact(PlanText.missed(missed), symbol: PlanText.commitmentSymbol)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("Today", "1")
            hint("This week", "2")
            hint("Switch", "⇥")
            hint(hasCurrentBrief ? "Rewrite" : "Write", "R")
            hint("Close", "Esc", "↩")
            Spacer()
            // Escape is the button's own key, so closing never depends on where focus is;
            // Return closes through `handle`.
            Button("Done") {
                close()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    /// One plan fact with its symbol in a fixed column, so the facts line up.
    private func fact(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 20)
            Text(text)
        }
    }

    /// "[Esc] [↩] Close": the keys that do one thing, then what they do.
    private func hint(_ label: String, _ keys: String...) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .monospaced()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            Text(label)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .fixedSize()
    }

    // MARK: State

    private var brief: Brief? {
        kind == .daily ? model.dailyBrief : model.weeklyBrief
    }

    private var isWriting: Bool {
        model.briefsInFlight.contains(kind)
    }

    /// A brief for today (or any weekly review) is on screen, so `r` replaces it.
    private var hasCurrentBrief: Bool {
        brief.map { model.isCurrent($0) } ?? false
    }

    private var writeTitle: String {
        if isWriting { return "Writing…" }
        if hasCurrentBrief { return "Rewrite" }
        if brief != nil { return "Write today's" }
        return kind == .daily ? "Write today's brief" : "Write this week's review"
    }

    private var emptyText: String {
        switch (kind, isWriting) {
        case (.daily, true): "Writing today's brief…"
        case (.weekly, true): "Writing this week's review…"
        case (.daily, false): "No brief for today yet. Press R to have one written from today's plan."
        case (.weekly, false): "No review for this week yet. Press R to have one written."
        }
    }

    /// "This brief is from yesterday." or "This brief is from Nov 6.": said above an earlier
    /// day's brief. `Brief.date` is a "YYYY-MM-DD" local day.
    private func staleNote(_ brief: Brief) -> String {
        let parts = brief.date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let day = model.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return "This brief is from an earlier day." }
        let name = model.calendar.isDateInYesterday(day) ? "yesterday" : DateText.day(day, calendar: model.calendar)
        return "This brief is from \(name)."
    }

    /// The body as one text, so a selection can run across its lines, with a small gap between
    /// them: the server sends three to six short sentences separated by newlines.
    private static func paragraphs(_ body: String) -> AttributedString {
        // An empty line set in a small font is a gap of about half a line.
        var gap = AttributedString("\n")
        gap.swiftUI.font = .system(size: 6)
        var text = AttributedString()
        for line in body.split(whereSeparator: \.isNewline) {
            if !text.characters.isEmpty {
                text.append(AttributedString("\n"))
                text.append(gap)
            }
            text.append(AttributedString(String(line)))
        }
        return text
    }

    // MARK: Actions

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // ⌘C on a selection, and every other chord, is not ours.
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        if press.key == .escape || press.key == .return {
            close()
            return .handled
        }
        if press.key == .tab {
            kind = kind == .daily ? .weekly : .daily
            return .handled
        }
        switch press.characters {
        case "1": kind = .daily
        case "2": kind = .weekly
        case "r", "R": write()
        default: return .ignored
        }
        return .handled
    }

    private func write() {
        guard !isWriting else { return }
        let model = model
        let kind = kind
        Task {
            await model.writeBrief(kind)
        }
    }

    private func close() {
        model.isBriefOpen = false
    }
}
