import Foundation
import Testing

struct WidgetPrivacyTests {
    @Test func widgetRootsDeclareSensitiveContentIncludingAccessibilityLabels() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let pattern = #"\.containerBackground\(\.fill\.tertiary, for: \.widget\)\s*\.privacySensitive\(\)"#
        for path in ["Today/TodayWidget.swift", "UpNext/UpNextWidget.swift", "Tasks/TasksWidget.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent("Widgets/\(path)"), encoding: .utf8)
            #expect(source.range(of: pattern, options: .regularExpression) != nil, "\(path) must mark its entire widget content private")
        }
    }
}
