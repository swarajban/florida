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
            WeekPager(selectedDay: selectedDay, today: today, calendar: calendar,
                      onSelect: onSelect, onShiftWeek: onShiftWeek)
            .frame(height: 43)
        }
        .clipped()
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(FloridaStyle.paper)
    }
}

private struct WeekPager: UIViewRepresentable {
    let selectedDay: Date
    let today: Date
    let calendar: Calendar
    let onSelect: (Date) -> Void
    let onShiftWeek: (Int) -> Void

    func makeUIView(context: Context) -> WeekPagerView {
        WeekPagerView(frame: .zero)
    }

    func updateUIView(_ view: WeekPagerView, context: Context) {
        view.update(selectedDay: selectedDay, today: today, calendar: calendar,
                    onSelect: onSelect, onShiftWeek: onShiftWeek)
    }
}

private final class WeekPagerView: UIScrollView, UIScrollViewDelegate {
    private var pages: [Date: UIView] = [:]
    private var buttons: [Date: WeekDateButton] = [:]
    private var weeks: [Date] = []
    private var selectedWeek: Date?
    private var selectedDay: Date?
    private var today: Date?
    private var calendar = Calendar.autoupdatingCurrent
    private var onSelect: ((Date) -> Void)?
    private var onShiftWeek: ((Int) -> Void)?
    private var pageWidth: CGFloat = 0
    private var dragStartIndex = 2
    private var isUserScroll = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isPagingEnabled = true
        alwaysBounceHorizontal = true
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        accessibilityIdentifier = "agenda-week-strip"
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is WeekDateButton || super.touchesShouldCancel(in: view)
    }

    func update(selectedDay: Date, today: Date, calendar: Calendar, onSelect: @escaping (Date) -> Void,
                onShiftWeek: @escaping (Int) -> Void) {
        self.calendar = calendar
        self.selectedDay = selectedDay
        self.today = today
        self.onShiftWeek = onShiftWeek
        self.onSelect = onSelect
        let selectedWeek = DateNavigation.startOfWeek(for: selectedDay, calendar: calendar)
        let changedWeek = self.selectedWeek != selectedWeek
        self.selectedWeek = selectedWeek
        let needsRunway = !weeks.contains(selectedWeek)
        if needsRunway { makeWeeks(around: selectedWeek) }
        renderPages()
        layoutIfNeeded()
        if changedWeek {
            isUserScroll = false
            position(on: selectedWeek, animated: !needsRunway && window != nil)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let resized = pageWidth != bounds.width
        pageWidth = bounds.width
        contentSize = CGSize(width: pageWidth * CGFloat(weeks.count), height: bounds.height)
        for (index, week) in weeks.enumerated() {
            guard let page = pages[week] else { continue }
            page.frame = CGRect(x: CGFloat(index) * pageWidth, y: 0,
                                width: pageWidth, height: bounds.height)
            for (column, day) in DateNavigation.days(in: week, calendar: calendar).enumerated() {
                buttons[day]?.frame = CGRect(x: CGFloat(column) * pageWidth / 7, y: 0,
                                            width: pageWidth / 7, height: bounds.height)
            }
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
        for week in Array(pages.keys) where !weeks.contains(week) {
            pages.removeValue(forKey: week)?.removeFromSuperview()
            for day in DateNavigation.days(in: week, calendar: calendar) { buttons.removeValue(forKey: day) }
        }
        for week in weeks {
            if pages[week] == nil {
                let page = UIView()
                page.clipsToBounds = true
                addSubview(page)
                pages[week] = page
                for day in DateNavigation.days(in: week, calendar: calendar) {
                    let button = WeekDateButton(frame: .zero)
                    button.addAction(UIAction { [weak self] _ in self?.onSelect?(day) }, for: .touchUpInside)
                    page.addSubview(button)
                    buttons[day] = button
                }
            }
            pages[week]?.isUserInteractionEnabled = week == selectedWeek
            pages[week]?.accessibilityElementsHidden = week != selectedWeek
        }
        if let selectedDay, let today {
            for (day, button) in buttons {
                button.update(day: day, selected: day == selectedDay, today: day == today, calendar: calendar)
            }
        }
        setNeedsLayout()
    }

    private func position(on week: Date, animated: Bool) {
        guard pageWidth > 0, let index = weeks.firstIndex(of: week) else { return }
        setContentOffset(CGPoint(x: CGFloat(index) * pageWidth, y: 0), animated: animated)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isUserScroll = true
        dragStartIndex = pageWidth > 0 ? Int((contentOffset.x / pageWidth).rounded()) : 2
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
        let index = min(4, max(0, Int((contentOffset.x / pageWidth).rounded())))
        let week = weeks[index]
        self.selectedWeek = week
        let delta = (calendar.dateComponents([.day], from: selectedWeek, to: week).day ?? 0) / 7
        if let selectedDay { self.selectedDay = DateNavigation.shift(selectedDay, by: 7 * delta, calendar: calendar) }
        renderPages()
        if delta != 0 { onShiftWeek?(delta) }
        replenish()
    }

    private func replenish() {
        guard let selectedWeek, let index = weeks.firstIndex(of: selectedWeek), index == 0 || index == 4 else { return }
        makeWeeks(around: selectedWeek)
        renderPages()
        layoutIfNeeded()
        position(on: selectedWeek, animated: false)
    }
}

private final class WeekDateButton: UIButton {
    private let number = UILabel()
    private let dot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        number.textAlignment = .center
        number.adjustsFontSizeToFitWidth = true
        number.adjustsFontForContentSizeCategory = true
        number.minimumScaleFactor = 0.5
        number.layer.cornerRadius = 17
        number.clipsToBounds = true
        number.isAccessibilityElement = false
        dot.layer.cornerRadius = 1.5
        dot.isAccessibilityElement = false
        addSubview(number)
        addSubview(dot)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(day: Date, selected: Bool, today: Bool, calendar: Calendar) {
        isSelected = selected
        number.text = "\(calendar.component(.day, from: day))"
        let font = UIFont.preferredFont(forTextStyle: .body)
        number.font = today ? UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor,
                                     size: font.pointSize) : font
        number.textColor = UIColor(selected ? FloridaStyle.paper : FloridaStyle.ink)
        number.backgroundColor = selected ? UIColor(FloridaStyle.ink) : .clear
        dot.backgroundColor = today ? UIColor(FloridaStyle.ink) : .clear
        accessibilityLabel = day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        accessibilityValue = today ? "Today" : ""
        accessibilityTraits = selected ? [.button, .selected] : .button
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        number.frame = CGRect(x: (bounds.width - 34) / 2, y: 0, width: 34, height: 34)
        dot.frame = CGRect(x: (bounds.width - 3) / 2, y: 38, width: 3, height: 3)
    }
}
