import FloridaKit
import SwiftUI

struct EventQuickAddComposer: View {
    private enum Field: String, Identifiable {
        case date, time, calendar, recurrence, location, title
        var id: String { rawValue }
    }

    let calendars: [CalendarInfo]
    let accounts: [GoogleAccount]
    let calendar: Calendar
    let onSave: (CalendarEvent, EventRecurrence?) -> Bool
    let onCancel: () -> Void
    let onOpenEditor: (CalendarEvent, EventRecurrence?) -> Void
    @State private var session: EventQuickAddSession
    @State private var activeField: Field?
    @State private var error: String?
    #if os(iOS)
    @State private var inputFocused = false
    @State private var correctionFocused = false
    #else
    @FocusState private var inputFocused: Bool
    @FocusState private var correctionFocused: Bool
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        event: CalendarEvent, calendars: [CalendarInfo], accounts: [GoogleAccount], calendar: Calendar,
        onSave: @escaping (CalendarEvent, EventRecurrence?) -> Bool,
        onCancel: @escaping () -> Void,
        onOpenEditor: @escaping (CalendarEvent, EventRecurrence?) -> Void
    ) {
        self.calendars = calendars
        self.accounts = accounts
        self.calendar = calendar
        self.onSave = onSave
        self.onCancel = onCancel
        self.onOpenEditor = onOpenEditor
        _session = State(initialValue: EventQuickAddSession(event: event, now: Date(), calendar: calendar))
    }

    private var destination: CalendarInfo? {
        session.destination(in: calendars, accounts: accounts)
    }

    private var canSave: Bool {
        session.validationMessage(in: calendars, accounts: accounts) == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Event").font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    input
                    preview
                    Text("No guests or invitations. Saved locally, then synced.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let message = error ?? visibleValidation {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("event-quick-add-error")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .accessibilityIdentifier("event-quick-add-scroll")
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                destinationLabel
                actions
            }
            .padding(20)
        }
        .background(FloridaStyle.paper)
        .foregroundStyle(FloridaStyle.ink)
        .tint(FloridaStyle.ink)
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
        .popover(item: $activeField) { field in
            correction(field)
        }
        .onAppear { inputFocused = true }
        .onChange(of: activeField) { _, field in
            if field == nil { inputFocused = true }
        }
        #if os(macOS)
        .frame(width: 560, height: 540)
        #endif
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(iOS)
            EventComposerTextField(
                placeholder: "Lunch tomorrow 12-1 at Blue Bottle #work",
                text: Binding(get: { session.text }, set: { session.updateText($0); error = nil }),
                focused: $inputFocused, identifier: "event-quick-add-input",
                onSubmit: { if activeField == nil { save() } })
            #else
            TextField("Lunch tomorrow 12-1 at Blue Bottle #work", text: Binding(
                get: { session.text },
                set: { session.updateText($0); error = nil }))
                .font(.body)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit { if activeField == nil { save() } }
                .accessibilityIdentifier("event-quick-add-input")
            #endif
            Text("Dates use month/day. Times use \(calendar.timeZone.identifier).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(FloridaStyle.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(FloridaStyle.rule))
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { open(.title) } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.draft.title.isEmpty ? "Event title" : session.draft.title)
                        .font(.title3.weight(.medium))
                        .multilineTextAlignment(.leading)
                    Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("6", modifiers: .command)
            .accessibilityIdentifier("event-quick-add-title")
            previewChips
            if session.hasCorrections {
                Button("Reset corrections") { session.resetCorrections(); error = nil }
                    .font(.caption)
                    .accessibilityIdentifier("event-quick-add-reset")
                Text("Corrections stay as you type until reset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #if os(macOS)
            Text("⌘1 Date · ⌘2 Time · ⌘3 Calendar · ⌘4 Repeat · ⌘5 Location · ⌘6 Title")
                .font(.caption2)
                .foregroundStyle(.secondary)
            #endif
        }
    }

    @ViewBuilder
    private var previewChips: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                chip(.date, value: dateText, symbol: "calendar", key: "1")
                chip(.time, value: timeText, symbol: "clock", key: "2")
                chip(.calendar, value: destination?.summary ?? "Choose calendar", symbol: "tray", key: "3")
                chip(.recurrence, value: recurrenceText, symbol: "repeat", key: "4")
                chip(.location, value: session.draft.location ?? "Add location", symbol: "mappin.and.ellipse", key: "5")
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    chip(.date, value: dateText, symbol: "calendar", key: "1")
                    chip(.time, value: timeText, symbol: "clock", key: "2")
                }
                GridRow {
                    chip(.calendar, value: destination?.summary ?? "Choose calendar", symbol: "tray", key: "3")
                    chip(.recurrence, value: recurrenceText, symbol: "repeat", key: "4")
                }
                GridRow {
                    chip(.location, value: session.draft.location ?? "Add location", symbol: "mappin.and.ellipse", key: "5")
                        .gridCellColumns(2)
                }
            }
        }
    }

    private func chip(_ field: Field, value: String, symbol: String, key: KeyEquivalent) -> some View {
        Button { open(field) } label: {
            Label(value, systemImage: symbol)
                .font(.caption)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FloridaStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(FloridaStyle.rule))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
        .accessibilityIdentifier("event-quick-add-\(field.rawValue)")
    }

    private var destinationLabel: some View {
        Button { open(.calendar) } label: {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SAVING TO").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    if let destination {
                        let email = accounts.first { $0.id == destination.accountId }?.email ?? "Account unavailable"
                        Text(destination.summary).font(.subheadline.weight(.semibold))
                        if destination.summary != email {
                            Text(email).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Choose calendar").font(.subheadline)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .multilineTextAlignment(.leading)
        .accessibilityLabel(destinationAccessibilityLabel)
        .accessibilityIdentifier("event-quick-add-destination")
    }

    private var actions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button { showEditor() } label: {
                Label("Details", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("e", modifiers: .command)
            .disabled(session.event(in: calendars, accounts: accounts, allowUntitled: true) == nil)
            .accessibilityIdentifier("event-quick-add-details")
            Button(action: save) {
                Label("Add event", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(FloridaStyle.paper)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave || activeField != nil)
            .accessibilityIdentifier("event-quick-add-save")
            #if os(macOS)
            .keyboardShortcut(.defaultAction)
            #endif
        }
        .font(.subheadline.weight(.semibold))
    }

    private func correction(_ field: Field) -> some View {
        VStack(spacing: 0) {
            Form {
                switch field {
                case .title:
                    #if os(iOS)
                    EventComposerTextField(
                        placeholder: "Title", text: Binding(get: { session.draft.title }, set: { session.setTitle($0) }),
                        focused: Binding(get: { correctionFocused }, set: { correctionFocused = $0 }),
                        identifier: "event-quick-add-edit-title", onSubmit: { activeField = nil })
                    #else
                    TextField("Title", text: Binding(get: { session.draft.title }, set: { session.setTitle($0) }))
                        .focused($correctionFocused)
                        .accessibilityIdentifier("event-quick-add-edit-title")
                    #endif
                case .location:
                    #if os(iOS)
                    EventComposerTextField(
                        placeholder: "Location", text: Binding(get: { session.draft.location ?? "" }, set: { session.setLocation($0) }),
                        focused: Binding(get: { correctionFocused }, set: { correctionFocused = $0 }),
                        identifier: "event-quick-add-edit-location", onSubmit: { activeField = nil })
                    #else
                    TextField("Location", text: Binding(get: { session.draft.location ?? "" }, set: { session.setLocation($0) }))
                        .focused($correctionFocused)
                        .accessibilityIdentifier("event-quick-add-edit-location")
                    #endif
                case .date:
                    DatePicker("Date", selection: Binding(get: { session.localStart }, set: { session.moveStart(to: $0) }), displayedComponents: .date)
                        .accessibilityIdentifier("event-quick-add-date-picker")
                case .time:
                    Toggle("All-day", isOn: Binding(get: { session.draft.allDay }, set: { session.setAllDay($0) }))
                        .accessibilityIdentifier("event-quick-add-all-day")
                    DatePicker("Starts", selection: Binding(get: { session.localStart }, set: { session.moveStart(to: $0) }), displayedComponents: session.draft.allDay ? [.date] : [.date, .hourAndMinute])
                        .accessibilityIdentifier("event-quick-add-start")
                    DatePicker("Ends", selection: Binding(get: { session.localEnd }, set: { session.setEnd($0) }), displayedComponents: session.draft.allDay ? [.date] : [.date, .hourAndMinute])
                        .accessibilityIdentifier("event-quick-add-end")
                case .calendar:
                    ForEach(orderedCalendars) { info in
                        Button {
                            session.chooseCalendar(info.id)
                            activeField = nil
                            error = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(info.summary).font(.body.weight(.medium))
                                Text(accounts.first { $0.id == info.accountId }?.email ?? "Account unavailable")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("event-quick-add-calendar-\(info.id)")
                    }
                case .recurrence:
                    EventRecurrenceSection(recurrence: Binding(get: { session.draft.recurrence }, set: { session.setRecurrence($0) }), timeZone: calendar.timeZone.identifier)
                }
            }
            .formStyle(.grouped)
            Button("Done") { activeField = nil }
                .keyboardShortcut(.defaultAction)
                .padding()
                .accessibilityIdentifier("event-quick-add-correction-done")
        }
        .onSubmit { activeField = nil }
        .onAppear {
            DispatchQueue.main.async { correctionFocused = field == .title || field == .location }
        }
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(width: 400, height: field == .recurrence || field == .calendar ? 380 : 260)
        #endif
    }

    private var orderedCalendars: [CalendarInfo] {
        calendars.filter { $0.accessRole == "owner" || $0.accessRole == "writer" }
            .sorted { CalendarInfo.isPreferredForNewEvents($0, $1, accounts: accounts) }
    }

    private var destinationAccessibilityLabel: String {
        guard let destination else { return "Choose a calendar and account before saving." }
        let account = accounts.first { $0.id == destination.accountId }?.email ?? "Account unavailable"
        return "Saving to \(destination.summary), account \(account)"
    }

    private var dateText: String {
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).month(.abbreviated).day().year()
        let start = session.localStart.formatted(style)
        if session.draft.allDay, !calendar.isDate(session.localStart, inSameDayAs: session.localEnd) {
            return "\(start)–\(session.localEnd.formatted(style))"
        }
        return start
    }

    private var timeText: String {
        guard !session.draft.allDay else { return "All day" }
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).hour().minute()
        let end = session.draft.endAt.formatted(style)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: session.draft.startAt), to: calendar.startOfDay(for: session.draft.endAt)).day ?? 0
        let endDay = days == 0 ? "" : " (+\(days) \(days == 1 ? "day" : "days"))"
        return "\(session.draft.startAt.formatted(style))–\(end)\(endDay)"
    }

    private var recurrenceText: String {
        guard let rule = session.draft.recurrence else { return "Does not repeat" }
        let unit: String = switch rule.frequency {
        case .daily: "day"
        case .weekly: "week"
        case .monthly: "month"
        case .yearly: "year"
        }
        let count = rule.count.map { " · \($0) times" } ?? ""
        return "Every \(rule.interval) \(unit)\(rule.interval == 1 ? "" : "s")\(count)"
    }

    private var visibleValidation: String? {
        if session.text.isEmpty, destination != nil { return nil }
        return session.validationMessage(in: calendars, accounts: accounts)
    }

    private func open(_ field: Field) {
        inputFocused = false
        activeField = field
    }

    private func showEditor() {
        guard let event = session.event(in: calendars, accounts: accounts, allowUntitled: true) else { return }
        inputFocused = false
        onOpenEditor(event, session.draft.recurrence)
    }

    private func save() {
        guard canSave, activeField == nil, let event = session.event(in: calendars, accounts: accounts) else { return }
        if !onSave(event, session.draft.recurrence) {
            error = "Could not save locally. Your draft is still here; check the app’s error and try again."
        }
    }
}
