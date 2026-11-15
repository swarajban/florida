import FloridaKit
import SwiftUI

struct AgendaListCarousel<Page: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder let page: (Date, DayAgenda?) -> Page
    @State private var runwayStart: Date?
    @State private var position = ScrollPosition(idType: Date.self)
    @State private var offset: CGFloat = 0
    @State private var isPanning = false

    private static var padding: Int { 7 }

    private var days: [Date] {
        let start = runwayStart ?? DateNavigation.shift(model.selectedDay, by: -Self.padding, calendar: model.calendar)
        return AppModel.gridDays(from: start, dayCount: 1 + 2 * Self.padding, calendar: model.calendar)
    }

    var body: some View {
        GeometryReader { proxy in
            carousel(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
        .onAppear {
            runwayStart = days.first
            observeDays()
        }
        .onDisappear { model.stopObservingGrid() }
    }

    private func carousel(width: CGFloat, height: CGFloat) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    page(day, model.gridDays.first { $0.day == day })
                        .frame(width: width, height: height)
                        .accessibilityHidden(day != model.selectedDay)
                        .id(day)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollPosition($position)
        .defaultScrollAnchor(.center)
        .scrollTargetBehavior(AgendaDayScrollTarget(pageWidth: width))
        .onAppear {
            position.scrollTo(id: model.selectedDay, anchor: .leading)
            offset = CGFloat(Self.padding) * width
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
            offset = x
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { isPanning = true }
            guard phase == .idle, isPanning, width > 0 else { return }
            isPanning = false
            let index = DayPaging.settledIndex(offset: Double(offset), pageWidth: Double(width), pageCount: days.count)
            let day = days[index]
            model.select(day: day)
            if index == 0 || index == days.count - 1 { recenter(on: day, width: width) }
        }
        .onChange(of: model.selectedDay) { _, day in
            isPanning = false
            if let index = days.firstIndex(of: day), index > 0, index < days.count - 1 {
                let x = CGFloat(index) * width
                guard abs(offset - x) > 1 else { return }
                withAnimation(.snappy(duration: 0.3)) { position.scrollTo(id: day, anchor: .leading) }
            } else {
                recenter(on: day, width: width)
            }
        }
        .onChange(of: width) { _, _ in
            position.scrollTo(id: model.selectedDay, anchor: .leading)
        }
    }

    private func observeDays() {
        guard let first = days.first else { return }
        model.setGridRange(start: first, dayCount: days.count)
    }

    private func recenter(on day: Date, width: CGFloat) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            runwayStart = DateNavigation.shift(day, by: -Self.padding, calendar: model.calendar)
            observeDays()
            offset = CGFloat(Self.padding) * width
            position.scrollTo(id: day, anchor: .leading)
        }
    }
}

private struct AgendaDayScrollTarget: ScrollTargetBehavior {
    let pageWidth: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard pageWidth > 0 else { return }
        target.rect.origin.x = CGFloat(DayPaging.targetOffset(
            proposed: Double(target.rect.minX), original: Double(context.originalTarget.rect.minX),
            pageWidth: Double(pageWidth), pageCount: Int((context.contentSize.width / pageWidth).rounded())))
    }
}
