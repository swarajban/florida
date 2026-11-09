import SwiftUI

/// Opens a meeting's video link. From two minutes before the start it counts down
/// ("Join · 1:42") and turns green, so it is obvious which meeting is about to begin.
struct JoinButton: View {
    let url: URL
    let start: Date?
    var controlSize: ControlSize = .regular
    @Environment(\.openURL) private var openURL

    static let countdownSeconds: TimeInterval = 120

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let countdown = start.flatMap { Self.countdown(to: $0, now: context.date) }
            Button {
                openURL(url)
            } label: {
                Label(countdown.map { "Join · \($0)" } ?? "Join", systemImage: "video.fill")
                    .monospacedDigit()
            }
            .buttonStyle(.borderedProminent)
            .tint(countdown == nil ? Color.accentColor : Color.green)
            .controlSize(controlSize)
            .help(url.absoluteString)
        }
    }

    /// "1:42" while the start is at most two minutes away, else nil.
    static func countdown(to start: Date, now: Date) -> String? {
        let remaining = start.timeIntervalSince(now)
        guard remaining > 0, remaining <= countdownSeconds else { return nil }
        let seconds = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
