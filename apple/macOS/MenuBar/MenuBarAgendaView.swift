import AppKit
import FloridaKit
import SwiftUI

/// The menu bar extra's window: today's date, the rest of today's meetings and task blocks with
/// a Join button per meeting, and a way back to the main window. Local data only.
struct MenuBarAgendaView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.clockNow.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            Divider()
            TimelineView(.everyMinute) { context in
                let entries = model.remainingAgenda(after: context.date)
                if entries.isEmpty {
                    Text("Nothing else today")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(entries) { entry in
                                AgendaRow(entry: entry, now: context.date)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 420)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack {
                Button("Open Florida") {
                    showMainWindow()
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
    }

    /// Brings the existing main window forward, or opens one if it was closed.
    private func showMainWindow() {
        NSApplication.shared.activate()
        // A closed window may linger unreleased; only a visible or minimized one is reused.
        if let window = model.mainWindow, window.isVisible || window.isMiniaturized {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: FloridaMacApp.mainWindowID)
        }
    }
}

/// One agenda line: time, color, title, and Join for meetings with a video link.
private struct AgendaRow: View {
    let entry: AgendaEntry
    let now: Date

    var body: some View {
        let isNow = entry.start <= now && now < entry.end
        let tint = entry.colorHex.flatMap(Color.init(hex:)) ?? (entry.isTask ? .defaultCategory : .defaultCalendar)
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(entry.isTask ? tint.opacity(0.5) : tint)
                .frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .lineLimit(1)
                    .foregroundStyle(entry.isTask ? Color.secondary : Color.primary)
                Text(isNow ? "Now · until \(DateText.time(entry.end))" : "\(DateText.timeRange(entry.start, entry.end)) · \(AppModel.untilText(entry.start, now: now))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            if let url = entry.joinURL {
                JoinButton(url: url, start: entry.start, controlSize: .small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(isNow ? Color.accentColor.opacity(0.08) : .clear)
    }
}
