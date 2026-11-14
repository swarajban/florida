import FloridaKit
import Foundation

extension AppModel {
    var taskListCalendar: Calendar {
        var result = calendar
        if let zone = TimeZone(identifier: userSettings?.timeZone ?? "") { result.timeZone = zone }
        return result
    }
}
