import SwiftUI

/// One of a task's two dates as a single row, so Start and Due sit one above the other and each
/// changes with one tap on its date. Without a date the whole row is an "Add" button. With one,
/// the row shows the date (and its time, when it has one) and a menu that adds or removes the
/// time, which few tasks need, and removes the date.
///
/// UI tests find the parts by `identifier`: "task-start" gives "task-start-add",
/// "task-start-date" and "task-start-options".
struct TaskDateRow: View {
    let title: String
    let identifier: String
    @Binding var isOn: Bool
    @Binding var date: Date
    @Binding var hasTime: Bool

    var body: some View {
        if isOn {
            // At large text sizes the date, the time and the menu do not fit beside the name.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(title)
                    Spacer(minLength: 8)
                    controls
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                    HStack(spacing: 8) {
                        controls
                        Spacer(minLength: 0)
                    }
                }
            }
        } else {
            Button {
                isOn = true
            } label: {
                HStack {
                    Text(title)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Label("Add", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Add a \(title.lowercased()) date")
            .accessibilityIdentifier("\(identifier)-add")
        }
    }

    @ViewBuilder
    private var controls: some View {
        DatePicker(title, selection: $date, displayedComponents: hasTime ? [.date, .hourAndMinute] : .date)
            .labelsHidden()
            .accessibilityIdentifier("\(identifier)-date")
        Menu {
            Button {
                hasTime.toggle()
            } label: {
                Label(hasTime ? "Remove the time" : "Add a time", systemImage: hasTime ? "clock.badge.xmark" : "clock")
            }
            Button(role: .destructive) {
                isOn = false
            } label: {
                Label("Remove the \(title.lowercased()) date", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(title) date options")
        .accessibilityIdentifier("\(identifier)-options")
    }
}
