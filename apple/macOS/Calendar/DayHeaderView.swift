import FloridaKit
import SwiftUI

/// Weekday, what kind of day it is (home, office, off) and day number above each column, then the
/// computer time still free on it; today is filled with ink, the highlighted day is outlined.
/// Click highlights a day, double-click opens it in the day view, right-click changes its kind.
struct DayHeaderView: View {
    @Environment(AppModel.self) private var model
    let gutterWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: gutterWidth, height: 0)
            ForEach(model.gridLayout.days, id: \.self) { day in
                let isToday = model.calendar.isDateInToday(day)
                let isSelected = model.calendar.isDate(day, inSameDayAs: model.selectedDay)
                let kind = model.dayKind(of: day)
                let isOverridden = model.dayOverride(on: day) != nil
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption)
                            .foregroundStyle(isToday ? FloridaStyle.ink : Color.secondary)
                        // Ink when the day was changed by hand, so an exception stands out from the routine.
                        Image(systemName: kind.symbolName)
                            .font(.system(size: 9, weight: isOverridden ? .semibold : .regular))
                            .foregroundStyle(isOverridden ? FloridaStyle.ink : Color.secondary.opacity(0.7))
                            .help(isOverridden ? "\(kind.label), changed for this date" : kind.label)
                            .accessibilityLabel(kind.label)
                            .accessibilityIdentifier("day-kind-\(DayOverride.key(for: day, calendar: model.calendar))")
                    }
                    Text(day.formatted(.dateTime.day()))
                        .font(.title3.weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? FloridaStyle.paper : FloridaStyle.ink)
                        .frame(width: 30, height: 30)
                        .background(isToday ? FloridaStyle.ink : .clear, in: Circle())
                        .overlay(Circle().strokeBorder(FloridaStyle.ink, lineWidth: isSelected && !isToday ? 1.5 : 0))
                    // Always a line, so the header keeps its height when a day has nothing to report.
                    Text(freeText(on: day) ?? " ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onClick { isDouble in
                    guard model.availabilityShare == nil else { return }
                    if isDouble {
                        model.goTo(day: day)
                        model.setViewMode(.day)
                    } else {
                        model.selectDay(day)
                    }
                }
                .contextMenu {
                    if model.availabilityShare == nil {
                        ForEach(DayKind.allCases, id: \.self) { choice in
                            Button {
                                model.setDay(day, kind: choice)
                            } label: {
                                Label(choice.label, systemImage: choice.symbolName)
                            }
                            .disabled(choice == kind)
                            .accessibilityIdentifier("day-header-set-\(choice.rawValue)")
                        }
                        Divider()
                        Button("Follow the Routine") {
                            model.clearDayOverride(on: day)
                        }
                        .disabled(!isOverridden)
                        .accessibilityIdentifier("day-header-follow-routine")
                    }
                }
            }
        }
    }

    /// "3h 15m free": computer time the plan has not filled, for days that are not over and that
    /// the scheduler reported.
    private func freeText(on day: Date) -> String? {
        guard day >= model.calendar.startOfDay(for: Date()), let free = model.freeMinutes(on: day) else { return nil }
        return PlanText.free(free.computer)
    }
}
