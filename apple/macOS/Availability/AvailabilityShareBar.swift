import FloridaKit
import SwiftUI

struct AvailabilityShareBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let share = model.availabilityShare {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Label("Share availability", systemImage: "rectangle.and.pencil.and.ellipsis")
                        .font(.headline)
                    Picker("Meeting", selection: Binding(
                        get: { share.meetingMinutes }, set: { model.setAvailabilityDuration($0) })
                    ) {
                        ForEach(Array(stride(from: 15, through: 240, by: 15)), id: \.self) { minutes in
                            Text("\(minutes)m").tag(minutes)
                        }
                    }
                    .frame(width: 130)
                    .accessibilityIdentifier("availability-duration")
                    Picker("Hours", selection: Binding(
                        get: { share.scheduleID ?? "" }, set: { model.setAvailabilitySchedule($0) })
                    ) {
                        ForEach(model.schedules) { schedule in
                            Text(schedule.name).tag(schedule.id)
                        }
                    }
                    .frame(maxWidth: 230)
                    .accessibilityIdentifier("availability-hours")
                    Spacer(minLength: 0)
                    Button(share.recipientZone?.identifier ?? "Recipient zone · Z") {
                        model.isAvailabilityZoneOpen = true
                    }
                    .accessibilityIdentifier("availability-zone")
                    Button("Cancel · Esc") { model.cancelAvailability() }
                    Button("Copy · ↩") { model.copyAvailability() }
                        .buttonStyle(.borderedProminent)
                        .disabled(share.selected.isEmpty)
                        .accessibilityIdentifier("availability-copy")
                }
                ScrollView(.vertical) {
                    Text(share.selected.isEmpty
                         ? (share.suggestions.isEmpty ? "No free time in these working hours. Choose another schedule or leave this mode to change days."
                            : "Select a suggested range with Space, or drag over free time.")
                         : model.availabilityText)
                        .font(.system(.body, design: .rounded))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("availability-preview")
                }
                .frame(height: 70)
                if let cursor = share.cursor {
                    Text("Focus: " + Availability.text([cursor], timeZone: model.calendar.timeZone))
                        .font(.caption)
                        .lineLimit(1)
                        .accessibilityIdentifier("availability-cursor")
                }
                if let warning = model.availabilitySyncWarning {
                    Label(warning, systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("availability-sync-warning")
                }
                Text("Drag to add · start inside a selected range to erase · Tab next suggestion · Space toggle · ↑↓ / HJKL move · Shift ↑↓ extend · 1–4 length · +/− 15m · orange: flexible tasks would move")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.blue.opacity(0.045))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("availability-bar")
            .onChange(of: model.clockNow) { model.refreshAvailability() }
            .onChange(of: model.userSettings?.timeZone) {
                model.startAvailabilityEvents()
                model.refreshAvailability()
            }
        }
    }
}

struct AvailabilityZoneSheet: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @FocusState private var isFocused: Bool

    private var matches: [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "_")
        return Availability.timeZoneIdentifiers.filter { text.isEmpty || $0.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recipient time zone").font(.title2)
            Text("Search the offline IANA list. Dates in both zones are included in the copied reply.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search, e.g. Tokyo or America/New_York", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .accessibilityIdentifier("availability-zone-search")
                .onSubmit {
                    if let first = matches.first { choose(first) }
                }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if matches.isEmpty {
                        Text("No matching IANA time zone").foregroundStyle(.secondary).padding(6)
                    }
                    ForEach(matches, id: \.self) { zone in
                        Button { choose(zone) } label: {
                            Text(zone).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 260)
            HStack {
                Button("Remove second zone") {
                    model.availabilityShare?.recipientZone = nil
                    model.isAvailabilityZoneOpen = false
                }
                Spacer()
                Button("Cancel") { model.isAvailabilityZoneOpen = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { isFocused = true }
    }

    private func choose(_ identifier: String) {
        model.availabilityShare?.recipientZone = TimeZone(identifier: identifier)
        model.isAvailabilityZoneOpen = false
        model.mainWindow?.makeFirstResponder(nil)
    }
}
