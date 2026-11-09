import FloridaKit
import SwiftUI

/// Sheet for one calendar event, timed or all day: title and time (with a "Day 2 of 3" cue for
/// multi-day events), a Join button when the event has a meeting link, calendar and account,
/// location (opens Maps), description with live links, guests and your own response. Opening
/// the event in Google Calendar is in the ⋯ menu. Read-only; Google is the source of truth.
struct EventDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let event: CalendarEvent

    var body: some View {
        let event = current
        let style = model.eventStyle(event)
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(AgendaItem.event(event).title)
                            .font(.title2.weight(.semibold))
                        Text(EventTiming.text(for: event, calendar: model.calendar))
                            .foregroundStyle(.secondary)
                        if let continuation = EventTiming.continuation(of: event, on: model.selectedDay, calendar: model.calendar) {
                            Label(continuation, systemImage: "arrow.right.to.line")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let badge = statusBadge(event) {
                            Label(badge, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    if let joinURL = event.joinURL {
                        JoinButton(url: joinURL, start: event.allDay ? nil : event.startAt)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                    }
                }

                Section {
                    HStack(spacing: 10) {
                        EventBar(style: style)
                            .frame(height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(style.calendarName ?? "Unknown calendar")
                            if let email = style.accountEmail {
                                Text(email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    if let location = event.location, !location.isEmpty {
                        Button {
                            if let url = Self.mapsURL(for: location) {
                                openURL(url)
                            }
                        } label: {
                            Label(location, systemImage: "mappin.and.ellipse")
                        }
                        .accessibilityHint("Opens in Maps")
                    }
                    LabeledContent("Your response") {
                        Label(EventTiming.responseText(event.responseStatus), systemImage: EventTiming.responseSymbol(event.responseStatus))
                    }
                }

                if let description = event.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                    Section("Description") {
                        Text(RichText.attributed(description))
                    }
                }

                if let attendees = event.attendees, !attendees.isEmpty {
                    EventAttendeesSection(attendees: attendees)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if let url = event.htmlLink.flatMap(URL.init(string:)) {
                            Button {
                                openURL(url)
                            } label: {
                                Label("Open in Google Calendar", systemImage: "arrow.up.right.square")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                    .disabled(event.htmlLink.flatMap(URL.init(string:)) == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The live row when the agenda still has it (a sync may have changed it), else the copy given.
    private var current: CalendarEvent {
        model.agenda?.events.first { $0.id == event.id } ?? event
    }

    private func statusBadge(_ event: CalendarEvent) -> String? {
        if event.isOutOfOffice { return "Out of office" }
        if event.status == "tentative" { return "Tentative" }
        if event.transparency == "transparent" { return "Shown as free" }
        return nil
    }

    /// A location that is itself a link (a video room) opens as is; anything else is a Maps search.
    static func mapsURL(for location: String) -> URL? {
        if let url = URL(string: location), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            return url
        }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: location)]
        return components?.url
    }
}
