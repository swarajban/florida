import SwiftUI

/// The prominent Join button of the event sheet. From two minutes before the start it counts
/// down ("Join · 1:42"), ticking once a second; it stays tappable throughout. The ticking runs
/// only around the event (from five minutes before the start until its end); the rest of the
/// time the view updates once a minute, or never when the event has no start.
struct JoinButton: View {
    let url: URL
    let start: Date?
    let end: Date?
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let start {
            TimelineView(.periodic(from: .now, by: 60)) { minute in
                if Self.countdownWindow(start: start, end: end).contains(minute.date) {
                    TimelineView(.periodic(from: .now, by: 1)) { second in
                        button(now: second.date)
                    }
                } else {
                    button(now: minute.date)
                }
            }
        } else {
            button(now: Date())
        }
    }

    /// When seconds matter: from five minutes before the start (a minute's lag in noticing still
    /// has the countdown ticking from two) to the end of the event.
    static func countdownWindow(start: Date, end: Date?) -> Range<Date> {
        start.addingTimeInterval(-300)..<max(end ?? start, start)
    }

    private func button(now: Date) -> some View {
        Button {
            openURL(url)
        } label: {
            Label(EventTiming.joinTitle(start: start, now: now), systemImage: "video.fill")
                .font(.headline.monospacedDigit())
                .frame(maxWidth: .infinity)
                .foregroundStyle(FloridaStyle.paper)
        }
        .buttonStyle(.borderedProminent)
        .tint(FloridaStyle.ink)
        .controlSize(.large)
        .accessibilityLabel(accessibilityTitle(now: now))
    }

    private func accessibilityTitle(now: Date) -> String {
        guard let seconds = EventTiming.secondsToStart(start: start, now: now) else { return "Join meeting" }
        return "Join meeting, starts in \(seconds / 60) minutes \(seconds % 60) seconds"
    }
}
