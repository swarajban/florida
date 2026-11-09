import FloridaKit
import SwiftUI

/// The guest list of the event sheet: organizer first, then you, then everyone else by name,
/// each with their response. The header counts the answers.
struct EventAttendeesSection: View {
    let attendees: [EventAttendee]

    var body: some View {
        Section {
            ForEach(sorted, id: \.email) { attendee in
                HStack(spacing: 10) {
                    Image(systemName: EventTiming.responseSymbol(attendee.responseStatus))
                        .foregroundStyle(tint(attendee.responseStatus))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name(of: attendee))
                        if attendee.displayName != nil {
                            Text(attendee.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(tags(of: attendee))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(EventTiming.responseText(attendee.responseStatus))
            }
        } header: {
            Text(header)
        }
    }

    private var sorted: [EventAttendee] {
        attendees.sorted { lhs, rhs in
            if lhs.organizer != rhs.organizer { return lhs.organizer }
            if lhs.isSelf != rhs.isSelf { return lhs.isSelf }
            return name(of: lhs).localizedCaseInsensitiveCompare(name(of: rhs)) == .orderedAscending
        }
    }

    /// "5 guests · 3 going, 1 maybe, 1 not answered".
    private var header: String {
        let counts = Dictionary(grouping: attendees, by: \.responseStatus).mapValues(\.count)
        let parts = ["accepted", "tentative", "declined", "needsAction"].compactMap { status in
            counts[status].map { "\($0) \(EventTiming.responseText(status).lowercased())" }
        }
        let guests = "\(attendees.count) \(attendees.count == 1 ? "guest" : "guests")"
        return ([guests] + parts).joined(separator: " · ")
    }

    private func name(of attendee: EventAttendee) -> String {
        attendee.displayName ?? attendee.email
    }

    private func tags(of attendee: EventAttendee) -> String {
        [attendee.isSelf ? "You" : nil, attendee.organizer ? "Organizer" : nil, attendee.optional ? "Optional" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func tint(_ status: String) -> Color {
        switch status {
        case "accepted": .green
        case "declined": .red
        case "tentative": .orange
        default: .secondary
        }
    }
}
