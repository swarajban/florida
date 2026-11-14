import AppKit
import FloridaKit
import SwiftUI

struct MacDateField: View {
    let title: String
    @Binding var date: Date
    var isOn: Binding<Bool>?
    var hasTime: Binding<Bool>?
    var key: String?
    var isPresented: Binding<Bool>?
    let identifier: String
    var showsLabel = true
    var onDismiss: () -> Void = {}
    var dayOnly: ((Date) -> Date)?
    var requiresTime = false
    @State private var localPresented = false
    @State private var originWindow: NSWindow?
    @State private var ownsOrigin = false
    @State private var origin = SelectorOrigin()
    @State private var anchorReady = false
    @Environment(\.calendar) private var calendar

    init(_ title: String, date: Binding<Date>, isOn: Binding<Bool>? = nil, hasTime: Binding<Bool>? = nil,
         key: String? = nil, isPresented: Binding<Bool>? = nil, identifier: String, showsLabel: Bool = true,
         onDismiss: @escaping () -> Void = {}, dayOnly: ((Date) -> Date)? = nil, requiresTime: Bool = false) {
        self.title = title
        _date = date
        self.isOn = isOn
        self.hasTime = hasTime
        self.key = key
        self.isPresented = isPresented
        self.identifier = identifier
        self.showsLabel = showsLabel
        self.onDismiss = onDismiss
        self.dayOnly = dayOnly
        self.requiresTime = requiresTime
    }

    private var presented: Binding<Bool> { isPresented ?? $localPresented }

    private var popoverPresented: Binding<Bool> {
        Binding(get: { presented.wrappedValue && anchorReady }, set: { presented.wrappedValue = $0 })
    }

    var body: some View {
        Group {
            if showsLabel {
                LabeledContent {
                    control
                } label: {
                    HStack(spacing: 6) {
                        Text(title)
                        if let key { Keycap(key) }
                    }
                }
            } else {
                control
            }
        }
        .onChange(of: presented.wrappedValue, initial: true) { wasOpen, isOpen in
            guard wasOpen != isOpen || isOpen else { return }
            if isOpen {
                originWindow = origin.window ?? originWindow ?? NSApp.keyWindow
                if let originWindow, !ownsOrigin {
                    SelectorWindowHost.register(originWindow)
                    ownsOrigin = true
                }
                origin.reveal()
                anchorReady = true
            } else {
                anchorReady = false
                releaseOrigin()
                Task { @MainActor in
                    await SelectorOrigin.finishDismissal(in: originWindow, onDismiss: onDismiss)
                }
            }
        }
        .onDisappear(perform: releaseOrigin)
    }

    private func releaseOrigin() {
        if ownsOrigin, let originWindow { SelectorWindowHost.unregister(originWindow) }
        ownsOrigin = false
    }

    private var control: some View {
        Button {
            originWindow = origin.window ?? NSApp.keyWindow
            presented.wrappedValue = true
        } label: {
            HStack(spacing: 6) {
                Text(isOn?.wrappedValue == false ? "No date" : label).lineLimit(1)
                Image(systemName: "calendar").foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier(identifier)
        .accessibilityValue(isOn?.wrappedValue == false ? "No date" : label)
        .background(SelectorOriginView(origin: origin))
        .popover(isPresented: popoverPresented, arrowEdge: .bottom) {
            MacDateSelector(title: title, current: date, hasTime: hasTime?.wrappedValue ?? false,
                            allowsTime: hasTime != nil, requiresTime: requiresTime,
                            allowsClear: isOn != nil, identifier: identifier) { result in
                switch result {
                case .date(let value, let timed):
                    hasTime?.wrappedValue = timed
                    date = timed ? value : (dayOnly?(value) ?? preservingClock(on: value))
                    isOn?.wrappedValue = true
                case .clear: isOn?.wrappedValue = false
                case .invalid: return
                }
                presented.wrappedValue = false
            } cancel: {
                presented.wrappedValue = false
            }
            .environment(\.calendar, calendar)
        }
    }

    private var label: String {
        var style: Date.FormatStyle = hasTime?.wrappedValue == true
            ? .dateTime.month(.abbreviated).day().year().hour().minute()
            : .dateTime.month(.abbreviated).day().year()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    private func preservingClock(on day: Date) -> Date {
        let clock = calendar.dateComponents([.hour, .minute, .second], from: date)
        return calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0,
                             second: clock.second ?? 0, of: day) ?? day
    }
}

struct MacDateSelector: View {
    let title: String
    let current: Date
    let hasTime: Bool
    let allowsTime: Bool
    let requiresTime: Bool
    let allowsClear: Bool
    let identifier: String
    let choose: (DateEntryResult) -> Void
    let cancel: () -> Void
    @Environment(\.calendar) private var calendar
    @State private var query = ""
    @State private var cursor = Date()
    @State private var clock = ""
    @State private var timed = false
    @State private var now = Date()
    @FocusState private var gridFocused: Bool

    private var parsed: DateEntryResult {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let result = DateEntry.parse(query, now: now, calendar: calendar)
            if case .date(let day, false) = result, timed { return withClock(on: day) }
            return result
        }
        if timed { return withClock(on: cursor) }
        return .date(calendar.startOfDay(for: cursor), hasTime: false)
    }

    private var preview: String {
        switch parsed {
        case .date(let date, let hasTime):
            var style: Date.FormatStyle = hasTime
                ? .dateTime.weekday(.wide).month(.wide).day().year().hour().minute()
                : .dateTime.weekday(.wide).month(.wide).day().year()
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            return date.formatted(style)
        case .clear: return allowsClear ? "No date" : "This date is required"
        case .invalid: return "Try ‘tomorrow’, ‘nov 20’ or ‘next mon 3pm’"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SelectorInput(text: $query, placeholder: "Type a date…", identifier: "\(identifier)-search", command: command)
                .frame(height: 26)
            Text(preview)
                .font(.callout.weight(.medium))
                .accessibilityIdentifier("\(identifier)-preview")
            Divider()
            ForEach(Array(DateEntryQuickChoice.allCases.enumerated()), id: \.element) { index, choice in
                if choice != .none || allowsClear {
                    Button {
                        quick(choice)
                    } label: {
                        HStack {
                            Text(choice.title)
                            Spacer()
                            Keycap(String(index + 1))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(identifier)-quick-\(choice.rawValue)")
                }
            }
            Divider()
            monthGrid
                .focusable()
                .focused($gridFocused)
                .onKeyPress(.leftArrow) { move(-1); return .handled }
                .onKeyPress(.rightArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-7); return .handled }
                .onKeyPress(.downArrow) { move(7); return .handled }
                .onKeyPress(.return) { submit(); return .handled }
                .onKeyPress(.escape) { cancel(); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "12345")) { press in
                    guard let number = Int(press.characters), DateEntryQuickChoice.allCases.indices.contains(number - 1) else { return .ignored }
                    quick(DateEntryQuickChoice.allCases[number - 1])
                    return .handled
                }
            if allowsTime {
                if !requiresTime {
                    Toggle("Add a time", isOn: $timed)
                        .toggleStyle(.checkbox)
                }
                if timed {
                    TextField("Time, e.g. 3pm", text: Binding(get: { clock }, set: {
                        clock = $0
                        if case .date(_, true) = DateEntry.parse(query, now: now, calendar: calendar) { query = "" }
                    }))
                        .accessibilityIdentifier("\(identifier)-time")
                        .onSubmit(submit)
                }
            }
            HStack {
                Text("Arrows move days · Tab: calendar / 1–5\n↩ choose · esc cancel")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Choose", action: submit)
                    .accessibilityIdentifier("\(identifier)-choose")
            }
        }
        .padding(12)
        .frame(width: 310)
        .background(SelectorWindowGuard())
        .onExitCommand(perform: cancel)
        .onAppear {
            cursor = current
            timed = hasTime
            clock = clockText(current)
            now = Date()
        }
        .onChange(of: query) {
            if case .date(let date, let explicitTime) = DateEntry.parse(query, now: now, calendar: calendar) {
                cursor = date
                timed = explicitTime || requiresTime
                if explicitTime { clock = clockText(date) }
            }
        }
        .onChange(of: timed) {
            if !timed, case .date(_, true) = DateEntry.parse(query, now: now, calendar: calendar) { query = "" }
        }
    }

    private func clockText(_ date: Date) -> String {
        String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }

    private func withClock(on date: Date) -> DateEntryResult {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 2001, parts.month ?? 1, parts.day ?? 1)
        return DateEntry.parse("\(day) \(clock)", now: now, calendar: calendar)
    }

    private var monthGrid: some View {
        var monthStyle = Date.FormatStyle().month(.wide).year()
        monthStyle.calendar = calendar
        monthStyle.timeZone = calendar.timeZone
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: cursor)) ?? cursor
        let offset = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let days = calendar.range(of: .day, in: .month, for: cursor)?.count ?? 31
        return VStack(spacing: 5) {
            HStack {
                Button { changeMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous month")
                Spacer()
                Text(cursor.formatted(monthStyle)).fontWeight(.semibold)
                Spacer()
                Button { changeMonth(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next month")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 3) {
                ForEach(0..<7, id: \.self) { column in
                    Text(calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + column) % 7])
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(0..<(offset + days), id: \.self) { cell in
                    if cell < offset {
                        Color.clear.frame(height: 25)
                    } else {
                        let day = calendar.date(byAdding: .day, value: cell - offset, to: first) ?? first
                        let selected = calendar.isDate(day, inSameDayAs: cursor)
                        Button {
                            cursor = day
                            query = ""
                            submit()
                        } label: {
                            Text(String(cell - offset + 1))
                                .frame(maxWidth: .infinity, minHeight: 25)
                                .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                .foregroundStyle(selected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func command(_ name: String) -> Bool {
        if !query.isEmpty, name == "moveLeft:" || name == "moveRight:" { return false }
        switch name {
        case "moveLeft:": move(-1)
        case "moveRight:": move(1)
        case "moveUp:": move(-7)
        case "moveDown:": move(7)
        case "insertNewline:": submit()
        case "cancelOperation:": cancel()
        case "insertTab:": gridFocused = true
        default: return false
        }
        return true
    }

    private func move(_ days: Int) {
        cursor = calendar.date(byAdding: .day, value: days, to: cursor) ?? cursor
        query = ""
    }

    private func changeMonth(_ months: Int) {
        cursor = calendar.date(byAdding: .month, value: months, to: cursor) ?? cursor
        query = ""
    }

    private func quick(_ choice: DateEntryQuickChoice) {
        if let date = DateEntry.quickDate(choice, now: now, calendar: calendar) {
            let result = timed ? withClock(on: date) : .date(date, hasTime: false)
            guard result != .invalid else { return }
            choose(result)
        } else if allowsClear { choose(.clear) }
    }

    private func submit() {
        switch parsed {
        case .invalid: return
        case .clear where !allowsClear: return
        default: choose(parsed)
        }
    }
}
