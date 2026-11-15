import FloridaKit
import SwiftUI

/// Seven day cells for the week containing `selectedDay`. Tap a day to select it; swipe
/// horizontally to move a week.
struct WeekStrip: View {
    let selectedDay: Date
    let today: Date
    let calendar: Calendar
    let onSelect: (Date) -> Void
    let onShiftWeek: (Int) -> Void
    @State private var runwayStart: Date?
    @State private var position = ScrollPosition(idType: Date.self)
    @State private var offset: CGFloat = 0
    @State private var isPanning = false

    private var selectedWeek: Date {
        DateNavigation.startOfWeek(for: selectedDay, calendar: calendar)
    }

    private var weeks: [Date] {
        let start = runwayStart ?? DateNavigation.shift(selectedWeek, by: -14, calendar: calendar)
        return (0..<5).map { DateNavigation.shift(start, by: 7 * $0, calendar: calendar) }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(DateNavigation.days(in: selectedDay, calendar: calendar), id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 2)
            .accessibilityHidden(true)
            GeometryReader { proxy in
                carousel(width: proxy.size.width)
            }
            .frame(height: 43)
        }
        .clipped()
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(FloridaStyle.paper)
    }

    private func page(_ week: Date) -> some View {
        HStack(spacing: 0) {
            ForEach(DateNavigation.days(in: week, calendar: calendar), id: \.self) { day in
                Button {
                    onSelect(day)
                } label: {
                    DayCell(day: day, isSelected: day == selectedDay, isToday: day == today, calendar: calendar)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityHidden(week != selectedWeek)
    }

    private func carousel(width: CGFloat) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(weeks, id: \.self) { week in
                    page(week).frame(width: width).id(week)
                }
            }
            .scrollTargetLayout()
            .frame(width: CGFloat(weeks.count) * width, height: 43)
        }
        .frame(width: width, height: 43)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("agenda-week-strip")
        .scrollPosition($position)
        .defaultScrollAnchor(.center)
        .scrollTargetBehavior(WeekScrollTarget(pageWidth: width))
        .onAppear {
            runwayStart = weeks.first
            position.scrollTo(id: selectedWeek, anchor: .leading)
            offset = 2 * width
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
            offset = x
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { isPanning = true }
            guard phase == .idle, width > 0 else { return }
            let index = min(4, max(0, Int((offset / width).rounded())))
            let week = weeks[index]
            if isPanning {
                isPanning = false
                let delta = (calendar.dateComponents([.day], from: selectedWeek, to: week).day ?? 0) / 7
                if delta != 0 { onShiftWeek(delta) }
            }
            if index == 0 || index == 4 { recenter(on: week, width: width) }
        }
        .onChange(of: selectedWeek) { _, week in
            isPanning = false
            if let index = weeks.firstIndex(of: week) {
                let x = CGFloat(index) * width
                guard abs(offset - x) > 1 else { return }
                withAnimation(.snappy(duration: 0.3)) { position.scrollTo(id: week, anchor: .leading) }
            } else {
                recenter(on: week, width: width)
            }
        }
        .onChange(of: width) { _, width in
            position.scrollTo(id: selectedWeek, anchor: .leading)
        }
    }

    private func recenter(on week: Date, width: CGFloat) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            runwayStart = DateNavigation.shift(week, by: -14, calendar: calendar)
            offset = 2 * width
            position.scrollTo(id: week, anchor: .leading)
        }
    }
}

private struct WeekScrollTarget: ScrollTargetBehavior {
    let pageWidth: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard pageWidth > 0 else { return }
        let start = (context.originalTarget.rect.minX / pageWidth).rounded() * pageWidth
        let proposed = (target.rect.minX / pageWidth).rounded() * pageWidth
        let x = min(max(proposed, start - pageWidth), start + pageWidth)
        target.rect.origin.x = min(max(0, x), max(0, context.contentSize.width - context.containerSize.width))
    }
}

/// Weekday initial over the day number; an ink circle marks selection and a dot marks today.
private struct DayCell: View {
    let day: Date
    let isSelected: Bool
    let isToday: Bool
    let calendar: Calendar

    var body: some View {
        VStack(spacing: 4) {
            Text("\(calendar.component(.day, from: day))")
                .font(.body.weight(isToday ? .bold : .regular))
                .foregroundStyle(isSelected ? FloridaStyle.paper : FloridaStyle.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: 34, height: 34)
                .background {
                    if isSelected {
                        Circle().fill(FloridaStyle.ink)
                    }
                }
            Circle()
                .fill(isToday ? FloridaStyle.ink : .clear)
                .frame(width: 3, height: 3)
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityValue(isToday ? "Today" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
