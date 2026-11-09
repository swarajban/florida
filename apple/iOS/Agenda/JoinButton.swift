import SwiftUI

/// The prominent Join button of the event sheet. From two minutes before the start it counts
/// down ("Join · 1:42"), ticking once a second; it stays tappable throughout.
struct JoinButton: View {
    let url: URL
    let start: Date?
    @Environment(\.openURL) private var openURL

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Button {
                openURL(url)
            } label: {
                Label(EventTiming.joinTitle(start: start, now: context.date), systemImage: "video.fill")
                    .font(.headline.monospacedDigit())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityLabel(accessibilityTitle(now: context.date))
        }
    }

    private func accessibilityTitle(now: Date) -> String {
        guard let seconds = EventTiming.secondsToStart(start: start, now: now) else { return "Join meeting" }
        return "Join meeting, starts in \(seconds / 60) minutes \(seconds % 60) seconds"
    }
}
