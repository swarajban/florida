import FloridaKit
import Foundation

struct AvailabilityShareState {
    var meetingMinutes = 30
    var scheduleID: String?
    var free: [AvailabilityRange] = []
    var events: [CalendarEvent] = []
    var suggestions: [AvailabilityRange] = []
    var selected: [AvailabilityRange] = []
    var cursor: AvailabilityRange?
    var recipientZone: TimeZone?
    var paint: Paint?
    var previousViewMode: CalendarViewMode?

    struct Paint {
        var day: Date
        var minute: Int
        var original: [AvailabilityRange]
        var removes: Bool
    }
}
