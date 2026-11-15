import FloridaKit
import SwiftUI
import UIKit

/// Seven day cells for the week containing `selectedDay`. Tap a day to select it; swipe
/// horizontally to move a week.
struct WeekStrip: View {
    let selectedDay: Date
    let today: Date
    let calendar: Calendar
    let onSelect: (Date) -> Void
    let onShiftWeek: (Int) -> Void

    private var selectedWeek: Date {
        DateNavigation.startOfWeek(for: selectedDay, calendar: calendar)
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
            WeekPager(selectedWeek: selectedWeek, calendar: calendar,
                      onShiftWeek: onShiftWeek, page: { AnyView(page($0)) })
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
}

private struct WeekPager: UIViewControllerRepresentable {
    let selectedWeek: Date
    let calendar: Calendar
    let onShiftWeek: (Int) -> Void
    let page: (Date) -> AnyView

    func makeUIViewController(context: Context) -> WeekPagerController {
        WeekPagerController()
    }

    func updateUIViewController(_ controller: WeekPagerController, context: Context) {
        controller.update(selectedWeek: selectedWeek, calendar: calendar, onShiftWeek: onShiftWeek, page: page)
    }
}

private final class WeekPagerController: UIViewController, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private var hosts: [Date: UIHostingController<AnyView>] = [:]
    private var weeks: [Date] = []
    private var selectedWeek: Date?
    private var calendar = Calendar.autoupdatingCurrent
    private var page: ((Date) -> AnyView)?
    private var onShiftWeek: ((Int) -> Void)?
    private var pageWidth: CGFloat = 0
    private var dragStartIndex = 2
    private var isUserScroll = false

    override func loadView() {
        view = scroll
        scroll.backgroundColor = .clear
        scroll.isPagingEnabled = true
        scroll.alwaysBounceHorizontal = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast
        scroll.accessibilityIdentifier = "agenda-week-strip"
        scroll.delegate = self
    }

    func update(selectedWeek: Date, calendar: Calendar, onShiftWeek: @escaping (Int) -> Void,
                page: @escaping (Date) -> AnyView) {
        loadViewIfNeeded()
        self.calendar = calendar
        self.onShiftWeek = onShiftWeek
        self.page = page
        let changedWeek = self.selectedWeek != selectedWeek
        self.selectedWeek = selectedWeek
        let needsRunway = !weeks.contains(selectedWeek)
        if needsRunway { makeWeeks(around: selectedWeek) }
        renderPages()
        view.layoutIfNeeded()
        if changedWeek {
            isUserScroll = false
            position(on: selectedWeek, animated: !needsRunway && view.window != nil)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let resized = pageWidth != scroll.bounds.width
        pageWidth = scroll.bounds.width
        scroll.contentSize = CGSize(width: pageWidth * CGFloat(weeks.count), height: scroll.bounds.height)
        for (index, week) in weeks.enumerated() {
            guard let host = hosts[week] else { continue }
            host.view.frame = CGRect(x: CGFloat(index) * pageWidth, y: 0,
                                     width: pageWidth, height: scroll.bounds.height)
        }
        if resized, let selectedWeek {
            isUserScroll = false
            position(on: selectedWeek, animated: false)
        }
    }

    private func makeWeeks(around week: Date) {
        weeks = (-2...2).map { DateNavigation.shift(week, by: 7 * $0, calendar: calendar) }
    }

    private func renderPages() {
        guard let page else { return }
        for week in Array(hosts.keys) where !weeks.contains(week) {
            guard let host = hosts.removeValue(forKey: week) else { continue }
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        for week in weeks {
            if let host = hosts[week] {
                host.rootView = page(week)
            } else {
                let host = UIHostingController(rootView: page(week))
                host.safeAreaRegions = []
                host.view.backgroundColor = .clear
                addChild(host)
                scroll.addSubview(host.view)
                host.didMove(toParent: self)
                hosts[week] = host
            }
        }
        view.setNeedsLayout()
    }

    private func position(on week: Date, animated: Bool) {
        guard pageWidth > 0, let index = weeks.firstIndex(of: week) else { return }
        scroll.setContentOffset(CGPoint(x: CGFloat(index) * pageWidth, y: 0), animated: animated)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isUserScroll = true
        dragStartIndex = pageWidth > 0 ? Int((scroll.contentOffset.x / pageWidth).rounded()) : 2
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                  targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard pageWidth > 0 else { return }
        let proposed = Int((targetContentOffset.pointee.x / pageWidth).rounded())
        let index = min(4, max(0, min(dragStartIndex + 1, max(dragStartIndex - 1, proposed))))
        targetContentOffset.pointee = CGPoint(x: CGFloat(index) * pageWidth, y: 0)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { replenish() }

    private func settle() {
        guard isUserScroll, pageWidth > 0, let selectedWeek else { return }
        isUserScroll = false
        let index = min(4, max(0, Int((scroll.contentOffset.x / pageWidth).rounded())))
        let week = weeks[index]
        self.selectedWeek = week
        let delta = (calendar.dateComponents([.day], from: selectedWeek, to: week).day ?? 0) / 7
        if delta != 0 { onShiftWeek?(delta) }
        replenish()
    }

    private func replenish() {
        guard let selectedWeek, let index = weeks.firstIndex(of: selectedWeek), index == 0 || index == 4 else { return }
        makeWeeks(around: selectedWeek)
        renderPages()
        view.layoutIfNeeded()
        position(on: selectedWeek, animated: false)
    }
}

/// An ink circle marks selection and a dot marks today.
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
