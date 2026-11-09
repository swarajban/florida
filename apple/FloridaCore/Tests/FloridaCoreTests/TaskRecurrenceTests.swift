import Foundation
import Testing
@testable import FloridaCore

@Suite struct TaskRecurrenceTests {
    private func task() -> TaskItem {
        TaskItem(id: "t", categoryId: "inbox", title: "Repeat", durationMinutes: 30,
                 createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test(arguments: TaskRecurrence.Frequency.allCases)
    func wireRoundTrip(_ frequency: TaskRecurrence.Frequency) throws {
        let rule = TaskRecurrence(
            frequency: frequency, interval: 3, timeZone: "America/Los_Angeles", startDate: "2026-11-09",
            weekdays: frequency == .week ? [1, 3, 5] : nil, dayOfMonth: frequency == .month ? 31 : nil,
            endDate: "2027-12-31")
        var task = task()
        task.recurrence = rule
        task.recurrenceSeriesId = "series"
        task.recurrenceDate = "2026-11-09"
        task.recurrenceRevision = "revision-1"
        let data = try JSONCoding.encoder.encode(task)
        #expect(try JSONCoding.decoder.decode(TaskItem.self, from: data) == task)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let recurrence = try #require(object["recurrence"] as? [String: Any])
        #expect(recurrence["frequency"] as? String == frequency.rawValue)
        #expect(recurrence["startDate"] as? String == "2026-11-09")
        #expect(recurrence["timeZone"] as? String == "America/Los_Angeles")
        #expect(object["recurrenceSeriesId"] as? String == "series")
        #expect(object["recurrenceDate"] as? String == "2026-11-09")
        #expect(object["recurrenceRevision"] as? String == "revision-1")

        let writeData = try JSONCoding.encoder.encode(TaskWrite(task))
        #expect(try JSONCoding.decoder.decode(TaskWrite.self, from: writeData).recurrence == rule)
        let write = try #require(JSONSerialization.jsonObject(with: writeData) as? [String: Any])
        #expect(write["recurrenceSeriesId"] == nil && write["recurrenceDate"] == nil)
        #expect(write["recurrenceRevision"] == nil)
        #expect(write["expectedRecurrenceRevision"] as? String == "revision-1")
    }

    @Test func legacyTaskAndWriteDefaultToNoRecurrence() throws {
        // The synthesized model encoder omits nil fields, just like a pre-recurrence server.
        let data = try JSONCoding.encoder.encode(task())
        let decoded = try JSONCoding.decoder.decode(TaskItem.self, from: data)
        #expect(decoded.recurrence == nil && decoded.recurrenceSeriesId == nil && decoded.recurrenceDate == nil)
        #expect(decoded.recurrenceRevision == nil)
        var write = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(TaskWrite(decoded))) as? [String: Any])
        write.removeValue(forKey: "recurrence")
        write.removeValue(forKey: "expectedRecurrenceRevision")
        let legacy = try JSONSerialization.data(withJSONObject: write)
        #expect(try JSONCoding.decoder.decode(TaskWrite.self, from: legacy).recurrence == nil)
        #expect(try JSONCoding.decoder.decode(TaskWrite.self, from: legacy).expectedRecurrenceRevision == nil)
    }

    @Test func omittedCustomDaysUseAnchor() throws {
        let weekly = TaskRecurrence(frequency: .week, timeZone: "Asia/Tokyo", startDate: "2026-11-09")
        #expect(weekly.effectiveWeekdays == [1])
        #expect(weekly.firstOccurrence == weekly.date(for: "2026-11-09"))
        let monthly = TaskRecurrence(frequency: .month, timeZone: "Asia/Tokyo", startDate: "2026-01-31")
        #expect(monthly.effectiveDayOfMonth == 31)
        #expect(monthly.validationMessage == nil)
        let payload = Data(#"{"frequency":"week","interval":2,"timeZone":"UTC","startDate":"2026-11-09"}"#.utf8)
        let decoded = try JSONCoding.decoder.decode(TaskRecurrence.self, from: payload)
        #expect(decoded.weekdays == nil && decoded.dayOfMonth == nil && decoded.endDate == nil)
    }

    @Test func customWeeklyIntervalStartsOnFirstEligibleWeek() {
        var rule = TaskRecurrence(frequency: .week, interval: 2, timeZone: "UTC", startDate: "2026-11-09", weekdays: [0])
        #expect(rule.firstOccurrence == rule.date(for: "2026-11-15"))
        rule.startDate = "2026-11-15"
        rule.weekdays = [1]
        #expect(rule.firstOccurrence == rule.date(for: "2026-11-23"))
        rule.startDate = "2026-11-09"
        rule.weekdays = [5, 3, 3]
        #expect(rule.effectiveWeekdays == [3, 5])
        #expect(rule.firstOccurrence == rule.date(for: "2026-11-11"))
        #expect(rule.validationMessage != nil, "duplicate weekdays are rejected by the wire contract")
        #expect(rule.summary.hasPrefix("Every 2 weeks on "))
    }

    @Test func customMonthlyDayClampsShortMonthsAndRespectsInterval() {
        var rule = TaskRecurrence(frequency: .month, timeZone: "UTC", startDate: "2028-02-01", dayOfMonth: 31)
        #expect(rule.firstOccurrence == rule.date(for: "2028-02-29"))
        #expect(rule.summary.contains("last day in shorter months"))
        rule.startDate = "2027-02-01"
        #expect(rule.firstOccurrence == rule.date(for: "2027-02-28"))
        rule.startDate = "2026-01-20"
        rule.dayOfMonth = 15
        rule.interval = 3
        #expect(rule.firstOccurrence == rule.date(for: "2026-04-15"))
    }

    @Test func upcomingPreviewSkipsHistoryAndRespectsLocalDatesAndInclusiveEnds() throws {
        let cases: [(TaskRecurrence, String, String)] = [
            (.init(frequency: .day, interval: 3, timeZone: "America/Los_Angeles", startDate: "2026-03-01"),
             "2026-03-08T19:00:00Z", "2026-03-10"),
            (.init(frequency: .week, interval: 2, timeZone: "UTC", startDate: "2026-11-09", weekdays: [1, 3]),
             "2026-11-12T12:00:00Z", "2026-11-23"),
            (.init(frequency: .week, interval: 2, timeZone: "UTC", startDate: "2026-11-09", weekdays: [1, 3]),
             "2026-11-23T12:00:00Z", "2026-11-23"),
            (.init(frequency: .month, timeZone: "America/Los_Angeles", startDate: "2028-01-31", dayOfMonth: 31),
             "2029-02-01T19:00:00Z", "2029-02-28"),
            (.init(frequency: .month, interval: 12, timeZone: "America/Los_Angeles", startDate: "2028-01-31"),
             "2035-02-01T19:00:00Z", "2036-01-31"),
        ]
        for (var rule, instant, expected) in cases {
            let now = try #require(JSONCoding.parseInstant(instant))
            #expect(rule.nextOccurrence(onOrAfter: now) == rule.date(for: expected))
            #expect(rule.validationMessage(asNewSeriesAt: now) == nil)
            rule.endDate = expected
            #expect(rule.nextOccurrence(onOrAfter: now) == rule.date(for: expected))
            let followingDay = try #require(rule.calendar.date(byAdding: .day, value: 1, to: rule.date(for: expected)!))
            #expect(rule.nextOccurrence(onOrAfter: followingDay) == nil)
            #expect(rule.validationMessage(asNewSeriesAt: followingDay) != nil)
            #expect(rule.validationMessage == nil, "an existing ended series remains editable")
        }
        let rule = TaskRecurrence(frequency: .day, timeZone: "America/Los_Angeles", startDate: "2026-11-09")
        let now = try #require(JSONCoding.parseInstant("2026-11-10T01:00:00Z"))
        #expect(rule.nextOccurrence(onOrAfter: now) == rule.date(for: "2026-11-09"))
    }

    @Test func datesAreLogicalInSelectedZoneAndValidateStrictly() {
        var rule = TaskRecurrence(frequency: .day, timeZone: "America/Los_Angeles", startDate: "2026-11-09")
        #expect(rule.dateString(for: JSONCoding.parseInstant("2026-11-10T01:00:00Z")!) == "2026-11-09")
        #expect(rule.date(for: "2026-02-30") == nil)
        #expect(rule.date(for: "2026-1-001") == nil)
        rule.endDate = rule.startDate
        #expect(rule.validationMessage == nil, "end date is inclusive")
        rule.endDate = "2026-11-08"
        #expect(rule.validationMessage != nil)
        rule.endDate = nil
        for interval in [0, 1000] {
            rule.interval = interval
            #expect(rule.validationMessage != nil)
        }
        rule.interval = 999
        #expect(rule.validationMessage == nil)
        rule.timeZone = "not/a-zone"
        #expect(rule.validationMessage != nil)
        rule.timeZone = "UTC"
        rule.frequency = .week
        for days in [[], [-1], [7]] {
            rule.weekdays = days
            #expect(rule.validationMessage != nil)
        }
    }

    @Test func enablingAlignsInputToAnchorNotFirstMatchAndLeavesReadOnlyMetadataAlone() {
        var task = task()
        task.recurrence = TaskRecurrence(frequency: .week, timeZone: "America/Los_Angeles", startDate: "2026-11-09", weekdays: [3])
        task.dueAt = JSONCoding.parseInstant("2026-11-09T17:00:00-08:00")
        task.startAt = JSONCoding.parseInstant("2026-11-08T09:30:00-08:00")
        task.pinnedStart = JSONCoding.parseInstant("2026-11-09T10:00:00-08:00")
        task.prepareToEnableRecurrence()
        #expect(task.startAt == JSONCoding.parseInstant("2026-11-09T09:30:00-08:00"))
        #expect(task.dueAt == JSONCoding.parseInstant("2026-11-09T17:00:00-08:00"))
        #expect(task.pinnedStart == JSONCoding.parseInstant("2026-11-09T10:00:00-08:00"))
        #expect(task.recurrence?.firstOccurrence == JSONCoding.parseInstant("2026-11-11T00:00:00-08:00"))
        #expect(task.deadlineType == .soft)
        #expect(task.recurrenceDate == nil && task.recurrenceSeriesId == nil)
    }

    @Test func defaultDayBoundsRespectDSTAndMidnightTransitions() {
        for zone in ["America/New_York", "America/Havana"] {
            var task = task()
            let rule = TaskRecurrence(frequency: .day, timeZone: zone, startDate: "2026-03-08")
            task.recurrence = rule
            task.prepareToEnableRecurrence()
            #expect(task.startAt == rule.date(for: "2026-03-08"))
            #expect(task.dueAt == rule.date(for: "2026-03-09")?.addingTimeInterval(-0.001))
            #expect(task.dueAt!.timeIntervalSince(task.startAt!) < 24 * 3600)
        }
    }
}
