import Foundation
import Testing
@testable import FloridaCore

@Suite struct AvailabilityTests {
    static let pacific = TimeZone(identifier: "America/Los_Angeles")!
    static let epoch = date("2026-11-12T00:00:00Z")

    static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    static func range(_ start: String, _ end: String) -> AvailabilityRange {
        AvailabilityRange(start: date(start), end: date(end))
    }

    static func hours(_ start: Int, _ end: Int) -> AvailabilityRange {
        AvailabilityRange(start: epoch.addingTimeInterval(Double(start) * 3600), end: epoch.addingTimeInterval(Double(end) * 3600))
    }

    static func schedule(
        zone: String = "America/Los_Angeles", days: [Int] = Array(0...6), start: String = "09:00", end: String = "17:00"
    ) -> Schedule {
        Schedule(
            id: "work", name: "Work", timeZone: zone, windows: [ScheduleWindow(days: days, start: start, end: end)],
            createdAt: epoch, updatedAt: epoch)
    }

    static func task(
        _ id: String, pin: Date? = nil, duration: Int = 60, completed: Int = 0, done: Bool = false, deleted: Bool = false
    ) -> TaskItem {
        TaskItem(
            id: id, categoryId: "work", title: "Private title", durationMinutes: duration, pinnedStart: pin,
            completedMinutes: completed, completedAt: done ? epoch : nil, createdAt: epoch, updatedAt: epoch,
            deletedAt: deleted ? epoch : nil)
    }

    static func placement(_ taskId: String, start: Int, end: Int, pinned: Bool = true) -> Placement {
        Placement(
            id: taskId, taskId: taskId, startAt: hours(start, end).start, endAt: hours(start, end).end,
            pinned: pinned, computedAt: epoch)
    }

    static func event() -> CalendarEvent {
        CalendarEvent(
            id: "event", calendarId: "calendar", googleId: "google", summary: "Private meeting",
            startAt: date("2026-11-12T18:10:00Z"), endAt: date("2026-11-12T19:05:00Z"), updatedAt: epoch)
    }

    static func free(
        _ visible: AvailabilityRange = range("2026-11-12T08:00:00Z", "2026-11-13T08:00:00Z"),
        schedules: [Schedule] = [schedule()], events: [CalendarEvent] = [], tasks: [TaskItem] = [],
        placements: [Placement] = [], commitments: [RoutineOccurrence] = [], now: Date = epoch
    ) -> [AvailabilityRange] {
        Availability.freeRanges(
            in: visible.start..<visible.end, schedules: schedules, events: events, tasks: tasks,
            placements: placements, commitments: commitments, now: now)
    }

    @Test func mergeSortsAndUnionsOverlappingNestedDuplicateAndAdjacentRanges() {
        #expect(Availability.merge([
            Self.hours(4, 6), Self.hours(1, 3), Self.hours(2, 4), Self.hours(1, 3), Self.hours(2, 2),
            Self.hours(8, 7), Self.hours(9, 10),
        ]) == [Self.hours(1, 6), Self.hours(9, 10)])
        #expect(Availability.merge([]).isEmpty)
    }

    @Test func somedayDoesNotBlockAvailabilityEvenWithAStalePinOrPlacement() {
        var task = Self.task("paused", pin: Self.hours(18, 19).start)
        task.someday = true
        #expect(Self.free(tasks: [task], placements: [Self.placement(task.id, start: 20, end: 21)]) == Self.free())
    }

    @Test func subtractSplitsClipsAndRespectsTouchingEndpoints() {
        #expect(Availability.subtract([Self.hours(1, 6)], removing: Self.hours(2, 4)) == [Self.hours(1, 2), Self.hours(4, 6)])
        #expect(Availability.subtract([Self.hours(1, 6)], removing: Self.hours(0, 3)) == [Self.hours(3, 6)])
        #expect(Availability.subtract([Self.hours(1, 6)], removing: Self.hours(3, 7)) == [Self.hours(1, 3)])
        #expect(Availability.subtract([Self.hours(1, 6)], removing: Self.hours(0, 7)).isEmpty)
        #expect(Availability.subtract([Self.hours(1, 6)], removing: Self.hours(6, 7)) == [Self.hours(1, 6)])
        #expect(Availability.subtract([Self.hours(1, 3), Self.hours(3, 6)], removing: Self.hours(4, 4)) == [Self.hours(1, 6)])
    }

    @Test func toggleSubtractsOnlyWhenFullyCoveredOtherwiseAddsTheWholeRange() {
        #expect(Availability.toggle(Self.hours(2, 4), in: [Self.hours(1, 3), Self.hours(3, 5)]) == [Self.hours(1, 2), Self.hours(4, 5)])
        #expect(Availability.toggle(Self.hours(2, 4), in: [Self.hours(1, 3)]) == [Self.hours(1, 4)])
        #expect(Availability.toggle(Self.hours(2, 4), in: [Self.hours(1, 2), Self.hours(4, 5)]) == [Self.hours(1, 5)])
        #expect(Availability.toggle(Self.hours(1, 3), in: [Self.hours(1, 3)]).isEmpty)
        #expect(Availability.toggle(Self.hours(4, 5), in: [Self.hours(1, 3)]) == [Self.hours(1, 3), Self.hours(4, 5)])
    }

    @Test func clippingKeepsOnlyFreePiecesMeetingTheMinimum() {
        let free = [Self.hours(1, 3), Self.hours(4, 6), Self.hours(6, 7)]
        #expect(Availability.clipped(Self.hours(2, 8), to: free, minimumMinutes: 60) == [Self.hours(2, 3), Self.hours(4, 7)])
        #expect(Availability.clipped(Self.hours(2, 8), to: free, minimumMinutes: 61) == [Self.hours(4, 7)])
        #expect(Availability.clipped(Self.hours(3, 4), to: free, minimumMinutes: 0).isEmpty)
        #expect(Availability.clipped(Self.hours(5, 2), to: free, minimumMinutes: -1).isEmpty)
    }

    @Test func selectingPartOfAnExtendedRangeDoesNotLeaveAnUnusableFragment() {
        let start = Self.date("2026-11-12T17:00:00Z")
        let suggestion = AvailabilityRange(start: start, end: start.addingTimeInterval(1800))
        let extended = AvailabilityRange(start: start, end: start.addingTimeInterval(2700))
        #expect(Availability.selection(Availability.toggle(suggestion, in: [extended]), minimumMinutes: 30).isEmpty)
        let moved = AvailabilityRange(start: start.addingTimeInterval(1800), end: start.addingTimeInterval(3600))
        #expect(Availability.selection(
            Availability.subtract([extended], removing: suggestion) + [moved], minimumMinutes: 30
        ) == [moved])
        #expect(Availability.selection([suggestion], minimumMinutes: 30) == [suggestion])
    }

    @Test func paintingIsSymmetricSnappedAndHasAOneSlotMinimum() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.pacific
        let day = Self.date("2026-11-12T08:00:00Z")
        let forward = Availability.paintedRange(on: day, fromMinute: 540, toMinute: 600, calendar: calendar)
        let backward = Availability.paintedRange(on: day, fromMinute: 600, toMinute: 540, calendar: calendar)
        #expect(forward == backward)
        #expect(forward == Self.range("2026-11-12T17:00:00Z", "2026-11-12T18:00:00Z"))
        #expect(Availability.paintedRange(on: day, fromMinute: 541, toMinute: 599, calendar: calendar) == forward)
        #expect(Availability.paintedRange(on: day, fromMinute: 540, toMinute: 540, calendar: calendar)
            == Self.range("2026-11-12T17:00:00Z", "2026-11-12T17:15:00Z"))
        #expect(Availability.paintedRange(on: day, fromMinute: 1440, toMinute: 1440, calendar: calendar)
            == Self.range("2026-11-13T07:45:00Z", "2026-11-13T08:00:00Z"))
    }

    @Test func eventPredicateUsesTimedLiveOpaqueNotDeclinedOrCancelledEventsOnly() {
        let event = Self.event()
        #expect(Availability.eventBlocksTime(event))
        var variants: [CalendarEvent] = []
        var changed = event
        changed.allDay = true
        variants.append(changed)
        changed = event
        changed.deletedAt = Self.epoch
        variants.append(changed)
        changed = event
        changed.status = "cancelled"
        variants.append(changed)
        changed = event
        changed.responseStatus = "declined"
        variants.append(changed)
        changed = event
        changed.transparency = "transparent"
        variants.append(changed)
        changed = event
        changed.startAt = nil
        variants.append(changed)
        changed = event
        changed.endAt = nil
        variants.append(changed)
        changed = event
        changed.endAt = event.startAt
        variants.append(changed)
        changed = event
        changed.endAt = Self.epoch
        variants.append(changed)
        #expect(variants.allSatisfy { !Availability.eventBlocksTime($0) })
        #expect(Self.free(events: variants) == Self.free())
        for response in ["accepted", "tentative", "needsAction"] {
            changed = event
            changed.status = "tentative"
            changed.responseStatus = response
            changed.transparency = "opaque"
            #expect(Availability.eventBlocksTime(changed))
        }
    }

    @Test func missingRoutineSettingsUseTheSameUTCFallbackAsTheServer() {
        #expect(Availability.routineTimeZone(nil) == .gmt)
        let settings = UserSettings(id: "settings", timeZone: "Asia/Tokyo", updatedAt: Self.epoch)
        #expect(Availability.routineTimeZone(settings) == TimeZone(identifier: "Asia/Tokyo"))
    }

    @Test func eventPolicyMatchesFocusLocationOutOfOfficeAndDayOverrides() {
        for type in ["focusTime", "workingLocation"] {
            var event = Self.event()
            event.eventType = type
            #expect(!Availability.eventBlocksTime(event))
            #expect(Self.free(events: [event]) == Self.free())
        }
        var event = Self.event()
        event.eventType = "outOfOffice"
        event.transparency = "transparent"
        #expect(Availability.eventBlocksTime(event))
        event.allDay = true
        #expect(Availability.eventBlocksTime(event))
        event.blocksDay = false
        #expect(!Availability.eventBlocksTime(event))
        event.eventType = "default"
        event.blocksDay = true
        #expect(Availability.eventBlocksTime(event))
        event.blocksDay = nil
        #expect(!Availability.eventBlocksTime(event))
        event.blocksDay = true
        event.responseStatus = "declined"
        #expect(!Availability.eventBlocksTime(event))
    }

    @Test func automaticAllDayJudgmentsAndManualPrecedenceProtectSharedAvailability() {
        for automatic in [false, true] {
            for manual: Bool? in [nil, false, true] {
                for outOfOffice in [false, true] {
                    var event = Self.event()
                    event.allDay = true
                    event.startAt = Self.date("2026-11-12T00:00:00Z")
                    event.endAt = Self.date("2026-11-13T00:00:00Z")
                    event.eventType = outOfOffice ? "outOfOffice" : "default"
                    event.transparency = "transparent"
                    event.autoBlocksDay = automatic
                    event.blocksDay = manual
                    let blocks = manual ?? automatic
                    #expect(Availability.eventBlocksTime(event) == blocks)
                    #expect(Self.free(events: [event]) == (blocks ? [] : Self.free()))
                }
            }
        }
    }

    @Test func allDayBlockingUsesTheRoutineDateAcrossDaylightSavingNotTheScheduleZone() {
        var event = Self.event()
        event.allDay = true
        event.eventType = "outOfOffice"
        event.startAt = Self.date("2026-11-01T00:00:00Z")
        event.endAt = Self.date("2026-11-02T00:00:00Z")
        let day = Self.range("2026-11-01T07:00:00Z", "2026-11-02T08:00:00Z")
        #expect(Availability.blockingRange(event, timeZone: Self.pacific) == day)
        let schedules = [Self.schedule(zone: "UTC", start: "00:00", end: "24:00")]
        let free = Availability.freeRanges(
            in: day.start..<day.end, schedules: schedules, events: [event], tasks: [], placements: [],
            commitments: [], now: day.start, timeZone: Self.pacific)
        #expect(free.isEmpty)
        event.blocksDay = false
        #expect(Availability.freeRanges(
            in: day.start..<day.end, schedules: schedules, events: [event], tasks: [], placements: [],
            commitments: [], now: day.start, timeZone: Self.pacific) == [day])
    }

    @Test func explicitAllDayProtectionUsesSpringForwardDayBounds() {
        var event = Self.event()
        event.allDay = true
        event.blocksDay = true
        event.startAt = Self.date("2026-03-08T00:00:00Z")
        event.endAt = Self.date("2026-03-09T00:00:00Z")
        #expect(Availability.blockingRange(event, timeZone: Self.pacific)
            == Self.range("2026-03-08T08:00:00Z", "2026-03-09T07:00:00Z"))
    }

    @Test func automaticTripCheckoutStaysAvailableUnlessManuallyBlocked() {
        var event = Self.event()
        event.allDay = true
        event.autoBlocksDay = true
        event.blockingReason = "Your trip"
        event.startAt = Self.date("2026-11-13T00:00:00Z")
        event.endAt = Self.date("2026-11-17T00:00:00Z")
        let checkout = Self.range("2026-11-16T08:00:00Z", "2026-11-17T08:00:00Z")
        for manual: Bool? in [nil, false, true] {
            event.blocksDay = manual
            let expected: AvailabilityRange? = manual == false ? nil
                : Self.range("2026-11-13T08:00:00Z", manual == true
                             ? "2026-11-17T08:00:00Z" : "2026-11-16T08:00:00Z")
            #expect(Availability.blockingRange(event, timeZone: Self.pacific) == expected)
            #expect(Self.free(checkout, events: [event], now: checkout.start)
                == (manual == true ? [] : Self.free(checkout, now: checkout.start)))
        }
    }

    @Test func workingHoursMinusEventsSnapInwardWithoutOfferingPastOrOffscreenTime() {
        let visible = Self.range("2026-11-12T17:05:00Z", "2026-11-12T21:53:00Z")
        #expect(Self.free(visible, events: [Self.event()], now: Self.date("2026-11-12T17:16:00Z")) == [
            Self.range("2026-11-12T17:30:00Z", "2026-11-12T18:00:00Z"),
            Self.range("2026-11-12T19:15:00Z", "2026-11-12T21:45:00Z"),
        ])
        #expect(Self.free(visible, now: visible.end).isEmpty)
        #expect(Self.free(AvailabilityRange(start: visible.end, end: visible.end)).isEmpty)
    }

    @Test func pinsWithoutPlacementsPinnedPlacementsAndCommitmentsBlockButFlexibleWorkDoesNot() {
        let tasks = [
            Self.task("pin", pin: Self.hours(18, 19).start, duration: 90, completed: 30),
            Self.task("placed"), Self.task("flexible"), Self.task("done", pin: Self.hours(17, 18).start, done: true),
            Self.task("deleted", deleted: true), Self.task("finished", pin: Self.hours(17, 18).start, completed: 60),
        ]
        let placements = [
            Self.placement("placed", start: 20, end: 21), Self.placement("flexible", start: 17, end: 25, pinned: false),
            Self.placement("done", start: 17, end: 25), Self.placement("deleted", start: 17, end: 25),
            Self.placement("missing", start: 17, end: 25), Self.placement("finished", start: 17, end: 25),
        ]
        let commitment = RoutineOccurrence(
            id: "gym", blockId: "gym", startAt: Self.hours(22, 23).start, endAt: Self.hours(22, 23).end, computedAt: Self.epoch)
        #expect(Self.free(tasks: tasks, placements: placements, commitments: [commitment]) == [
            Self.hours(17, 18), Self.hours(19, 20), Self.hours(21, 22), Self.hours(23, 25),
        ])
    }

    @Test func unionsWindowsBeforeSnappingAndSubtractsOverlappingBlockersOnce() {
        var schedule = Self.schedule()
        schedule.windows = [
            ScheduleWindow(days: [4], start: "09:00", end: "09:08"),
            ScheduleWindow(days: [4], start: "09:08", end: "17:00"),
        ]
        var secondEvent = Self.event()
        secondEvent.startAt = Self.date("2026-11-12T19:00:00Z")
        secondEvent.endAt = Self.date("2026-11-12T20:00:00Z")
        #expect(Self.free(schedules: [schedule, schedule], events: [Self.event(), secondEvent, Self.event()]) == [
            Self.hours(17, 18), Self.hours(20, 25),
        ])
    }

    @Test func filtersDeletedInvalidOrNonmatchingSchedulesAndWindowsWithNoFallback() {
        var deleted = Self.schedule()
        deleted.deletedAt = Self.epoch
        let invalid = [
            deleted, Self.schedule(zone: "Invalid/Zone"), Self.schedule(days: [5]),
            Self.schedule(start: "17:00", end: "09:00"), Self.schedule(start: "9:00"),
            Self.schedule(start: "-1:00"), Self.schedule(end: "24:01"), Self.schedule(end: "12:60"),
        ]
        #expect(Self.free(schedules: invalid).isEmpty)
        #expect(Self.free(schedules: []).isEmpty)
    }

    @Test func unionsAdjacentWindowsFromDifferentTimeZonesBeforeSnapping() {
        #expect(Self.free(schedules: [
            Self.schedule(start: "09:00", end: "09:08"),
            Self.schedule(zone: "America/New_York", start: "12:08", end: "13:00"),
        ]) == [Self.hours(17, 18)])
    }

    @Test func honorsEachSchedulesLocalWeekdayAcrossUtcDatesAndMultipleDays() {
        let visible = Self.range("2026-11-12T00:00:00Z", "2026-11-14T00:00:00Z")
        #expect(Self.free(visible, schedules: [Self.schedule(zone: "Asia/Tokyo", days: [5], start: "00:00", end: "02:00")]) == [
            Self.range("2026-11-12T15:00:00Z", "2026-11-12T17:00:00Z"),
        ])
        #expect(Self.free(visible, schedules: [Self.schedule(days: [4, 5])]) == [
            Self.range("2026-11-12T17:00:00Z", "2026-11-13T01:00:00Z"),
            Self.range("2026-11-13T17:00:00Z", "2026-11-14T00:00:00Z"),
        ])
    }

    @Test func endAtTwentyFourMeansTheNextLocalMidnight() {
        #expect(Self.free(schedules: [Self.schedule(start: "23:00", end: "24:00")]) == [
            Self.range("2026-11-13T07:00:00Z", "2026-11-13T08:00:00Z"),
        ])
    }

    @Test func springForwardUsesWallClockWindowsAndSkipsNonexistentTime() {
        let visible = Self.range("2026-03-08T08:00:00Z", "2026-03-09T07:00:00Z")
        let schedule = Self.schedule(days: [0], start: "00:00", end: "04:00")
        #expect(Self.free(visible, schedules: [schedule], now: visible.start) == [
            Self.range("2026-03-08T08:00:00Z", "2026-03-08T11:00:00Z"),
        ])
        #expect(Self.free(visible, schedules: [Self.schedule(start: "02:15", end: "04:00")], now: visible.start) == [
            Self.range("2026-03-08T10:00:00Z", "2026-03-08T11:00:00Z"),
        ])
    }

    @Test func fallBackIncludesBothHoursAndUsesFirstOccurrenceForAmbiguousWindowBounds() {
        let visible = Self.range("2026-11-01T07:00:00Z", "2026-11-02T08:00:00Z")
        #expect(Self.free(visible, schedules: [Self.schedule(start: "00:00", end: "03:00")], now: visible.start) == [
            Self.range("2026-11-01T07:00:00Z", "2026-11-01T11:00:00Z"),
        ])
        #expect(Self.free(visible, schedules: [Self.schedule(start: "01:15", end: "01:45")], now: visible.start) == [
            Self.range("2026-11-01T08:15:00Z", "2026-11-01T08:45:00Z"),
        ])
    }

    @Test func snapsNearestQuarterIncludingSecondsTiesMidnightAndBothDstFolds() {
        let cases = [
            ("2026-11-12T17:07:29Z", "2026-11-12T17:00:00Z"),
            ("2026-11-12T17:07:30Z", "2026-11-12T17:15:00Z"),
            ("2026-11-13T07:59:00Z", "2026-11-13T08:00:00Z"),
            ("2026-03-08T09:59:00Z", "2026-03-08T10:00:00Z"),
            ("2026-11-01T08:59:00Z", "2026-11-01T09:00:00Z"),
            ("2026-11-01T08:22:00Z", "2026-11-01T08:15:00Z"),
            ("2026-11-01T09:22:00Z", "2026-11-01T09:15:00Z"),
        ]
        for (input, expected) in cases {
            #expect(Availability.snapped(Self.date(input), timeZone: Self.pacific) == Self.date(expected))
        }
        let quarter = Self.date("2026-11-12T17:15:00Z")
        #expect(Availability.snapped(quarter.addingTimeInterval(0.2), timeZone: Self.pacific) == quarter)
        let nepal = TimeZone(identifier: "Asia/Kathmandu")!
        #expect(Availability.snapped(Self.date("2026-11-12T17:22:00Z"), timeZone: nepal) == Self.date("2026-11-12T17:15:00Z"))
    }

    @Test func freeRangeSnappingPreservesTheSecondRepeatedHour() {
        let visible = Self.range("2026-11-01T09:07:00Z", "2026-11-01T09:56:00Z")
        #expect(Self.free(visible, schedules: [Self.schedule(start: "00:00", end: "03:00")], now: visible.start) == [
            Self.range("2026-11-01T09:15:00Z", "2026-11-01T09:45:00Z"),
        ])
    }

    @Test func textShowsYearsRolloverAndEachRecipientsOwnDate() {
        let ranges = [Self.range("2026-12-31T07:30:00Z", "2026-12-31T09:00:00Z")]
        let text = Availability.text(ranges, timeZone: Self.pacific, recipientTimeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(text.contains("Wed, Dec 30, 2026"))
        #expect(text.contains("Thu, Dec 31, 2026"))
        #expect(text.contains("11:30 PM"))
        #expect(text.contains("1:00 AM"))
        #expect(text.contains("4:30–6:00 PM"))
        #expect(text.contains("6:00 PM"))
        #expect(text.contains("America/Los_Angeles"))
        #expect(text.contains("Asia/Tokyo"))
        #expect(text.components(separatedBy: "America/Los_Angeles").count == 2)
        #expect(text.components(separatedBy: "Asia/Tokyo").count == 2)
        let yearChange = Availability.text(
            [Self.range("2027-01-01T07:30:00Z", "2027-01-01T08:30:00Z")], timeZone: Self.pacific)
        #expect(yearChange.contains("Dec 31, 2026"))
        #expect(yearChange.contains("Jan 1, 2027"))
    }

    @Test func textLabelsBothOffsetsAcrossDstAndDoesNotRepeatIdenticalZones() {
        let ranges = [Self.range("2026-11-01T08:30:00Z", "2026-11-01T09:30:00Z")]
        let text = Availability.text(ranges, timeZone: Self.pacific)
        #expect(text == "Sun, Nov 1, 2026: 1:30 AM PDT–1:30 AM PST")
        #expect(text.contains("2026"))
        #expect(Availability.text(ranges, timeZone: Self.pacific, recipientTimeZone: Self.pacific) == text)
        #expect(Availability.text([], timeZone: Self.pacific).isEmpty)
        #expect(Availability.text([Self.hours(3, 2)], timeZone: Self.pacific).isEmpty)
    }

    @Test func textUsesCompactTimesWithOneSharedPeriodAndZoneUnlessTheyChange() {
        let afternoon = [Self.range("2026-11-17T22:00:00Z", "2026-11-17T23:30:00Z")]
        #expect(Availability.text(afternoon, timeZone: Self.pacific) == "Tue, Nov 17, 2026: 2:00–3:30 PM PST")
        let noon = [Self.range("2026-11-17T19:30:00Z", "2026-11-17T20:30:00Z")]
        #expect(Availability.text(noon, timeZone: Self.pacific) == "Tue, Nov 17, 2026: 11:30 AM–12:30 PM PST")
        let midnight = [Self.range("2026-11-18T07:30:00Z", "2026-11-18T08:30:00Z")]
        #expect(Availability.text(midnight, timeZone: Self.pacific) == "Tue, Nov 17, 2026: 11:30 PM – Wed, Nov 18, 2026: 12:30 AM PST")
    }

    @Test func textNamesAmbiguousZonesOnceRatherThanRepeatingTheirIdentifierPerRange() {
        let central = TimeZone(identifier: "America/Chicago")!
        let ranges = [
            Self.range("2026-11-17T22:00:00Z", "2026-11-17T23:30:00Z"),
            Self.range("2026-11-18T22:00:00Z", "2026-11-18T23:30:00Z"),
        ]
        let text = Availability.text(ranges, timeZone: central)
        #expect(text.hasPrefix("America/Chicago:\n"))
        #expect(text.components(separatedBy: "America/Chicago").count == 2)
        #expect(text.contains("4:00–5:30 PM CST"))
    }

    @Test func offlineTimeZonesAreSortedUniqueFoundationIdentifiers() {
        let identifiers = Availability.timeZoneIdentifiers
        #expect(identifiers == identifiers.sorted())
        #expect(identifiers.count == Set(identifiers).count)
        #expect(identifiers.contains("America/Los_Angeles"))
        #expect(identifiers.contains("Asia/Tokyo"))
        #expect(identifiers.allSatisfy { TimeZone(identifier: $0) != nil })
    }
}
