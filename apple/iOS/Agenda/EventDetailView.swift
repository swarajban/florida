import FloridaKit
import SwiftUI

/// Sheet for one calendar event, timed or all day: title and time (with a "Day 2 of 3" cue for
/// multi-day events), a Join button when the event has a meeting link, calendar and account,
/// location (opens Maps), description with live links, guests and your own response, which is
/// Yes / Maybe / No buttons when you are a guest. On a calendar you can write to, Edit opens the
/// editor and the ⋯ menu (which also opens the event in Google Calendar) deletes the event.
struct EventDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var editing = false
    @State private var confirmingDelete = false
    #if DEBUG
    @State private var recordedResourceURL: URL?
    #endif
    let event: CalendarEvent

    var body: some View {
        let event = current
        let resources = event.resources
        let style = model.eventStyle(event)
        let canEdit = model.canEdit(event)
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
                        JoinButton(url: joinURL, start: event.allDay ? nil : event.startAt, end: event.allDay ? nil : event.endAt)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                    }
                }

                if !resources.isEmpty {
                    Section("Resources") {
                        ForEach(resources) { resource in
                            Button {
                                openResource(resource)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "link")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(resource.title)
                                        Text(resource.kindLabel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityLabel("\(resource.title), \(resource.kindLabel)")
                            .accessibilityValue(resourceValue(resource))
                            .accessibilityHint("Opens in your browser or the linked app")
                            .accessibilityIdentifier("event-resource-\(resource.id)")
                        }
                    }
                }

                if event.allDay {
                    Section {
                        Picker("Blocks my day", selection: Binding(
                            get: { event.blocksDay },
                            set: { model.setBlocksDay(event, blocksDay: $0) })) {
                            Text("Automatic").tag(nil as Bool?)
                            Text("Blocks").tag(true as Bool?)
                            Text("Does not block").tag(false as Bool?)
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("event-blocks-day-\(event.id)")
                        .accessibilityValue(event.blocksDay.map { $0 ? "Blocks" : "Does not block" } ?? "Automatic")
                        let calendarBlocks = model.calendarInfo(id: event.calendarId)?.blocksScheduling ?? true
                        Text(calendarBlocks && event.isVisible && (event.blocksDay ?? event.isOutOfOffice)
                            ? "Blocks your day" : "Does not block scheduling")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("event-blocks-day-effective-\(event.id)")
                    } footer: {
                        Text("Automatic blocks only out-of-office events. Florida only; this occurrence only. Google Calendar is unchanged.")
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
                    if model.canRespond(to: event) {
                        responseRow(event)
                    } else {
                        LabeledContent("Your response") {
                            Label(EventTiming.responseText(event.responseStatus), systemImage: EventTiming.responseSymbol(event.responseStatus))
                        }
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if canEdit {
                        Button("Edit") {
                            editing = true
                        }
                    }
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarLeading) {
                    let link = event.htmlLink.flatMap(URL.init(string:))
                    Menu {
                        if let link {
                            Button {
                                openURL(link)
                            } label: {
                                Label("Open in Google Calendar", systemImage: "arrow.up.right.square")
                            }
                        }
                        if canEdit {
                            Button(role: .destructive) {
                                confirmingDelete = true
                            } label: {
                                Label("Delete Event", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                    .disabled(link == nil && !canEdit)
                    // On the menu itself, so the dialog opens anchored to it (see Binding+Dialogs).
                    .confirmationDialog("Delete this event?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("Delete Event", role: .destructive) {
                            model.delete(event: event)
                            dismiss()
                        }
                    }
                }
            }
            .sheet(isPresented: $editing) {
                EventEditorView(event: current, isNew: false)
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The live row when the agenda still has it (a sync may have changed it), else the store's
    /// copy (a declined or moved event leaves the day while staying in the store), else the copy given.
    private var current: CalendarEvent {
        model.agenda?.events.first { $0.id == event.id } ?? model.storedVersion(of: event)
    }

    private func openResource(_ resource: EventResource) {
        #if DEBUG
        if LaunchOptions.demoData, UserDefaults.standard.bool(forKey: "uiRecordResourceOpens") {
            recordedResourceURL = resource.url
            return
        }
        #endif
        openURL(resource.url)
    }

    private func resourceValue(_ resource: EventResource) -> String {
        #if DEBUG
        if recordedResourceURL == resource.url {
            return "Opened \(resource.url.absoluteString)"
        }
        #endif
        return resource.url.absoluteString
    }

    /// Yes / Maybe / No in place of the "Your response" line, the current answer filled. A tap
    /// writes the answer locally at once; the sheet reads the store's row, so it follows.
    private func responseRow(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your response")
            HStack(spacing: 8) {
                responseButton("Yes", status: "accepted", event: event)
                responseButton("Maybe", status: "tentative", event: event)
                responseButton("No", status: "declined", event: event)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your response")
        .accessibilityValue(EventTiming.responseText(event.responseStatus))
    }

    @ViewBuilder
    private func responseButton(_ title: String, status: String, event: CalendarEvent) -> some View {
        let selected = event.responseStatus == status
        let button = Button {
            model.respond(to: event, status: status)
        } label: {
            Label(title, systemImage: EventTiming.responseSymbol(status))
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .tint(selected ? Self.responseTint(status) : .secondary)
        .accessibilityAddTraits(selected ? .isSelected : [])
        // Two styles, so the chosen answer is filled and the others outlined; a List row with
        // several buttons needs explicit styles for each to take only its own taps.
        if selected {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    /// The attendee list's colors for the same answers.
    private static func responseTint(_ status: String) -> Color {
        switch status {
        case "accepted": .green
        case "declined": .red
        default: .orange
        }
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
