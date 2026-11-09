import FloridaKit
import SwiftUI

/// How an event is drawn: its Google calendar's color as the fill, and a rim in its account's hue
/// so work and personal events read apart even when their calendars share a color. Accounts have
/// no color of their own, so each gets one from `accountHues` by its position in the account
/// list (sorted by email, so stable while the set of accounts is).
struct EventStyle: Hashable {
    static let accountHues: [Color] = [.indigo, .orange, .teal, .pink, .brown, .mint]

    var fill: Color
    var rim: Color?
    var calendarName: String?
    var accountEmail: String?
    var accountLabel: String?

    init(event: CalendarEvent, calendars: [CalendarInfo], accounts: [GoogleAccount]) {
        let info = calendars.first { $0.id == event.calendarId }
        fill = info?.color.flatMap(Color.init(hex:)) ?? .secondary
        calendarName = info?.summary
        if let info, let index = accounts.firstIndex(where: { $0.id == info.accountId }) {
            let account = accounts[index]
            rim = Self.accountHues[index % Self.accountHues.count]
            accountEmail = account.email
            accountLabel = account.label
        }
    }

    /// "Work calendar, work account" for VoiceOver.
    var accessibilityDescription: String {
        [calendarName.map { "\($0) calendar" }, accountLabel.map { "\($0) account" }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

extension AppModel {
    func eventStyle(_ event: CalendarEvent) -> EventStyle {
        EventStyle(event: event, calendars: calendars, accounts: accounts)
    }
}

/// The vertical bar in front of an event: calendar color with a hairline rim in the account hue.
struct EventBar: View {
    let style: EventStyle
    var width: CGFloat = 5

    var body: some View {
        RoundedRectangle(cornerRadius: width / 2)
            .fill(style.fill)
            .overlay {
                if let rim = style.rim {
                    RoundedRectangle(cornerRadius: width / 2)
                        .strokeBorder(rim, lineWidth: 1)
                }
            }
            .frame(width: width)
            .accessibilityHidden(true)
    }
}
