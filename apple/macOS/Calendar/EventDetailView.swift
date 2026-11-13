import AppKit
import FloridaKit
import SwiftUI

/// The `↩` / double-click popover for a Google event: title, time, calendar and account,
/// location, description with live links, guests with their responses, and Join. "Open in Google
/// Calendar" lives in the ⋯ menu.
///
/// On a calendar the user can write to it also answers an invitation (Yes / Maybe / No) and
/// offers Edit and Delete; on a read-only calendar it only shows the response. The keymap's event
/// keys (`v`, `r y` / `r m` / `r n`, ⇧E, `x`, `o`) work while it is open, through its own key
/// monitor, and each control shows its key.
struct EventDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var observedEvent: CalendarEvent?
    private let initialEvent: CalendarEvent

    init(event: CalendarEvent) {
        initialEvent = event
    }

    private var event: CalendarEvent {
        observedEvent ?? model.storedVersion(of: initialEvent)
    }

    var body: some View {
        let resources = event.resources
        ScrollView {
            detailContent(resources)
                .padding(16)
        }
        .frame(width: 400, alignment: .leading)
        .frame(maxHeight: min(620, (NSScreen.main?.visibleFrame.height ?? 700) - 80))
        .fixedSize(horizontal: false, vertical: true)
        .background(KeyEventMonitorView(model: model, isEventPopover: true))
        .onChange(of: resources) { model.eventResourceKeys = nil }
        .task(id: initialEvent.id) {
            guard let database = model.database else { return }
            do {
                for try await row in database.observeEvent(id: initialEvent.id) {
                    observedEvent = row
                }
            } catch {
                if !Task.isCancelled {
                    model.statusMessage = "Could not read the event: \(error.localizedDescription)"
                }
            }
        }
    }

    private func detailContent(_ resources: [EventResource]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            #if DEBUG
            HeldKeyDiagnostics(keys: ["1"])
            #endif
            if event.allDay {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Blocks my day")
                        Spacer()
                        Self.keycap(for: .cycleEventDayBlocking)
                    }
                    .help(Self.hint(for: .cycleEventDayBlocking))
                    DayBlockingControl(
                        blocksDay: Binding(
                            get: { model.storedVersion(of: event).blocksDay },
                            set: { model.setBlocksDay(event, blocksDay: $0) }),
                        identifier: "event-blocks-day-\(event.id)")
                    let calendarBlocks = model.calendarsById[event.calendarId]?.blocksScheduling ?? true
                    Text(AllDayBlocking.isEffective(event, calendarBlocksScheduling: calendarBlocks)
                        ? "Blocks your day" : "Does not block scheduling")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("event-blocks-day-effective-\(event.id)")
                    Text(AllDayBlocking.explanation(for: event))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("event-blocking-reason-\(event.id)")
                    Text("Florida only; this occurrence only. Google Calendar is unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let url = event.joinURL {
                HStack(spacing: 8) {
                    JoinButton(url: url, start: event.startAt)
                    Self.keycap(for: .joinMeeting)
                }
            }
            if !resources.isEmpty {
                resourceShelf(resources)
            }
            if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
                Label {
                    Text(EventText.linked(location))
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "mappin.and.ellipse")
                }
            }
            if let description = event.description, !description.isEmpty {
                ScrollView {
                    Text(EventText.attributed(description))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let attendees = event.attendees, !attendees.isEmpty {
                EventAttendeeList(attendees: attendees)
            }
            if model.canRespond(to: event) {
                responseButtons
            } else if let rsvp = Self.rsvpText(event.responseStatus) {
                Label(rsvp, systemImage: EventAttendeeList.symbol(for: event.responseStatus ?? ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.canEdit(event) {
                Divider()
                HStack {
                    Button {
                        model.openEventEditor(event)
                    } label: {
                        Self.keyLabel("Edit…", for: .editEvent)
                    }
                    .help(Self.hint(for: .editEvent))
                    Spacer()
                    Button(role: .destructive) {
                        model.confirmDelete(event)
                    } label: {
                        Self.keyLabel("Delete…", for: .core(.delete))
                    }
                    .help(Self.hint(for: .core(.delete)))
                }
            }
        }
    }

    private func resourceShelf(_ resources: [EventResource]) -> some View {
        let labels = JumpLabels(items: resources.map(\.id), alphabet: Array("1234567890"))
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                model.run(.openEventResources)
            } label: {
                HStack(spacing: 6) {
                    Text("Resources")
                        .font(.caption.weight(.semibold))
                    Self.keycap(for: .openEventResources)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Resources")
            .help(Self.hint(for: .openEventResources))
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(resources) { resource in
                        Button {
                            model.openEventResource(resource)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(resource.title)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Text(resource.kindLabel)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if let key = (model.eventResourceKeys ?? labels).remaining[resource.id] {
                                    Keycap(key.map(String.init).joined(separator: " "))
                                } else if labels.remaining[resource.id] == nil {
                                    Self.keycap(for: .openEventResources)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(FloridaStyle.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help(labels.remaining[resource.id] == nil
                              ? "Open event resources (g r) to find this link: \(resource.url.absoluteString)"
                              : resource.url.absoluteString)
                        .accessibilityLabel("\(resource.title), \(resource.kindLabel)")
                        .accessibilityIdentifier("event-resource-\(resource.id)")
                        .accessibilityValue(labels.remaining[resource.id] ?? "g r")
                    }
                }
            }
            .accessibilityIdentifier("event-resource-shelf")
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Yes / Maybe / No for an invitation, with the current answer shown pressed.
    private var responseButtons: some View {
        HStack(spacing: 8) {
            Text("Going?")
                .foregroundStyle(.secondary)
            responseButton("Yes", status: "accepted", command: .respondYes)
            responseButton("Maybe", status: "tentative", command: .respondMaybe)
            responseButton("No", status: "declined", command: .respondNo)
        }
        .font(.callout)
    }

    private func responseButton(_ title: String, status: String, command: MacCommand) -> some View {
        let isCurrent = Binding(
            get: { event.responseStatus == status },
            set: { _ in model.respond(to: event, status: status) })
        return Toggle(isOn: isCurrent) {
            HStack(spacing: 5) {
                Label(title, systemImage: EventAttendeeList.symbol(for: status))
                Self.keycap(for: command)
            }
            .fixedSize()
        }
        .toggleStyle(.button)
        .help(Self.hint(for: command))
    }

    /// The keys bound to `command`, as a keycap: "V", "R Y".
    private static func keycap(for command: MacCommand) -> Keycap {
        Keycap(MacKeymap.default.bindings(for: command).first.map(MacKeymap.keycap) ?? "")
    }

    private static func keyLabel(_ title: String, for command: MacCommand) -> some View {
        HStack(spacing: 6) {
            Text(title)
            keycap(for: command)
        }
    }

    /// "RSVP: Yes (r y)" — a button's tooltip: the command it runs and the keys bound to it.
    private static func hint(for command: MacCommand) -> String {
        "\(command.label) (\(MacKeymap.default.shortcut(for: command)))"
    }

    private var header: some View {
        let info = model.calendarsById[event.calendarId]
        let email = info.flatMap { calendar in model.accounts.first { $0.id == calendar.accountId }?.email }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.summary?.isEmpty == false ? event.summary ?? "" : "(No title)")
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
                Menu {
                    Button("Open in Google Calendar (\(MacKeymap.default.shortcut(for: .core(.openInGoogle))))") {
                        model.openInGoogle(event)
                    }
                    .disabled(event.htmlLink == nil)
                    Button("Copy Link") { model.copyLink(of: event) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Text(Self.timeText(event, calendar: model.calendar))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle()
                    .fill(info?.tint ?? .defaultCalendar)
                    .frame(width: 8, height: 8)
                Text(info?.summary ?? "Calendar")
                if let email {
                    Text(email)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .lineLimit(1)
        }
    }

    /// "Mon, Nov 9 · 2:00 PM – 2:30 PM (30m)", or "All day · Mon, Nov 9" / "All day · Nov 9 – Nov 11".
    static func timeText(_ event: CalendarEvent, calendar: Calendar) -> String {
        guard let start = event.startAt, let end = event.endAt else { return "" }
        let dayStyle = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        if event.allDay {
            let days = AllDayDate.localDays(start: start, end: end, calendar: calendar)
            let lastDay = DateNavigation.shift(days.upperBound, by: -1, calendar: calendar)
            return lastDay > days.lowerBound
                ? "All day · \(days.lowerBound.formatted(dayStyle)) – \(lastDay.formatted(dayStyle))"
                : "All day · \(days.lowerBound.formatted(dayStyle))"
        }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        let range = calendar.isDate(start, inSameDayAs: end)
            ? "\(start.formatted(dayStyle)) · \(DateText.timeRange(start, end))"
            : "\(start.formatted(dayStyle)) \(DateText.time(start)) – \(end.formatted(dayStyle)) \(DateText.time(end))"
        return "\(range) (\(DateText.duration(minutes: minutes)))"
    }

    /// Your own response in words, for calendars it cannot be changed on; nil when you are not a guest.
    static func rsvpText(_ status: String?) -> String? {
        switch status {
        case "accepted": "You're going"
        case "declined": "You declined"
        case "tentative": "You said maybe"
        case "needsAction": "You haven't responded"
        default: nil
        }
    }
}

extension View {
    /// Shows the detail popover for `eventId` while it is the model's open event, anchored at
    /// `anchor` in this view. Each calendar surface attaches it where the event is drawn; pass nil
    /// when the open event is not drawn here.
    func eventDetailPopover(
        _ model: AppModel, eventId: String?, anchor: PopoverAttachmentAnchor = .rect(.bounds), indicatorDay: Date? = nil
    ) -> some View {
        let isPresented = Binding(
            get: { eventId != nil && model.eventDetailID == eventId && model.eventDetailIndicatorDay == indicatorDay },
            set: {
                if !$0, model.eventDetailID == eventId, model.eventDetailIndicatorDay == indicatorDay {
                    model.eventDetailID = nil
                }
            })
        return popover(isPresented: isPresented, attachmentAnchor: anchor, arrowEdge: .trailing) {
            if let eventId, let event = model.eventForDetail(id: eventId) {
                EventDetailView(event: event)
                    .environment(model)
            }
        }
    }
}
