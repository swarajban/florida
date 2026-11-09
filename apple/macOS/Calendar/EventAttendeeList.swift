import FloridaKit
import SwiftUI

/// Guests of an event with their response, organizer first; scrolls past about eight rows.
struct EventAttendeeList: View {
    let attendees: [EventAttendee]

    var body: some View {
        let sorted = attendees.sorted { a, b in
            if a.organizer != b.organizer { return a.organizer }
            return Self.name(a).localizedCaseInsensitiveCompare(Self.name(b)) == .orderedAscending
        }
        VStack(alignment: .leading, spacing: 6) {
            Text(summary)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sorted, id: \.email) { attendee in
                        HStack(spacing: 6) {
                            Image(systemName: Self.symbol(for: attendee.responseStatus))
                                .foregroundStyle(Self.tint(for: attendee.responseStatus))
                                .frame(width: 14)
                            Text(Self.name(attendee))
                                .lineLimit(1)
                            if attendee.isSelf {
                                Text("you")
                                    .foregroundStyle(.secondary)
                            }
                            if attendee.organizer {
                                Text("organizer")
                                    .foregroundStyle(.secondary)
                            } else if attendee.optional {
                                Text("optional")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(.callout)
                        .help(attendee.email)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 170)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "6 guests · 4 yes, 1 maybe, 1 awaiting".
    private var summary: String {
        let counts = Dictionary(grouping: attendees, by: \.responseStatus).mapValues(\.count)
        var parts: [String] = []
        if let yes = counts["accepted"] { parts.append("\(yes) yes") }
        if let no = counts["declined"] { parts.append("\(no) no") }
        if let maybe = counts["tentative"] { parts.append("\(maybe) maybe") }
        if let awaiting = counts["needsAction"] { parts.append("\(awaiting) awaiting") }
        let guests = "\(attendees.count) guest\(attendees.count == 1 ? "" : "s")"
        return parts.isEmpty ? guests : "\(guests) · \(parts.joined(separator: ", "))"
    }

    static func name(_ attendee: EventAttendee) -> String {
        if let name = attendee.displayName, !name.isEmpty { return name }
        return attendee.email
    }

    static func symbol(for status: String) -> String {
        switch status {
        case "accepted": "checkmark.circle.fill"
        case "declined": "xmark.circle.fill"
        case "tentative": "questionmark.circle.fill"
        default: "circle.dashed"
        }
    }

    static func tint(for status: String) -> Color {
        switch status {
        case "accepted": .green
        case "declined": .red
        case "tentative": .orange
        default: .secondary
        }
    }
}
