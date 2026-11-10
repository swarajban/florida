import SwiftUI

/// The "Why here?" sheet: a sentence or two from the server's model on why a task is planned
/// where it is. It opens at once with a spinner; the answer or the error replaces it when it
/// arrives in `AppModel.explanation`. ↩ or Esc closes.
struct ExplanationSheet: View {
    @Environment(AppModel.self) private var model
    /// The explanation last shown, so the sheet keeps its words while it closes.
    @State private var last: PlacementExplanation?
    @FocusState private var isFocused: Bool

    var body: some View {
        let explanation = model.explanation ?? last
        VStack(alignment: .leading, spacing: 14) {
            Text("Why here?")
                .font(.headline)
            if let explanation {
                Text(explanation.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                answer(explanation)
                    // Room for a two-sentence answer (four lines), so the sheet rarely resizes when it arrives.
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            }
            HStack {
                Spacer()
                // Escape is the button's own key, so closing never depends on where focus is;
                // Return closes through the key handler below.
                Button("Done") {
                    close()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
        // The sheet itself holds focus so key presses arrive here.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: .down) { press in
            guard press.key == .escape || press.key == .return else { return .ignored }
            close()
            return .handled
        }
        .onAppear {
            isFocused = true
        }
        .onChange(of: model.explanation, initial: true) { _, explanation in
            if let explanation {
                last = explanation
            }
        }
    }

    @ViewBuilder
    private func answer(_ explanation: PlacementExplanation) -> some View {
        if explanation.isLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Asking…")
                    .foregroundStyle(.secondary)
            }
        } else if let error = explanation.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .accessibilityIdentifier("explanation-error")
        } else if let text = explanation.text {
            Text(text)
                .font(.title3)
                .lineSpacing(4)
                .textSelection(.enabled)
                .accessibilityIdentifier("explanation-text")
        }
    }

    private func close() {
        model.explanation = nil
    }
}
