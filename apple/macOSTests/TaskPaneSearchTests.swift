import AppKit
import FloridaKit
import Testing

@Suite(.serialized) @MainActor
struct TaskPaneSearchTests {
    @Test func focusIsExplicitAndDismissalPreservesTheQuery() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let field = TaskPaneSearchField(frame: NSRect(x: 12, y: 80, width: 300, height: 24))
        field.isEditable = true
        field.stringValue = "#work"
        let content = try #require(window.contentView)
        content.addSubview(field)
        window.initialFirstResponder = field
        window.makeKeyAndOrderFront(nil)
        #expect(field.currentEditor() == nil)

        for chord in [KeyChord("escape"), KeyChord("return")] {
            field.focusForClick()
            try #require(TaskPaneSearchField.editing(in: window) === field)
            #expect(field.handleKey(KeyChord("j")) == nil)
            #expect(field.handleKey(chord) == true)
            #expect(TaskPaneSearchField.editing(in: window) == nil)
            #expect(field.stringValue == "#work")
        }

        field.focusForClick()
        field.releaseFocusIfOutside(field.convert(NSPoint(x: 20, y: 10), to: nil))
        #expect(TaskPaneSearchField.editing(in: window) === field)
        field.releaseFocusIfOutside(field.convert(NSPoint(x: 20, y: -10), to: nil))
        #expect(TaskPaneSearchField.editing(in: window) == nil)

        field.focusForClick()
        NotificationCenter.default.post(name: NSWindow.willBeginSheetNotification, object: window)
        #expect(TaskPaneSearchField.editing(in: window) == nil)
        window.makeFirstResponder(field)
        #expect(!(window.firstResponder is NSTextView), "Responder after sheet focus restore: \(String(describing: window.firstResponder))")
        field.focusForClick()
        field.removeFromSuperview()
        content.addSubview(field)
        window.makeFirstResponder(field)
        #expect(!(window.firstResponder is NSTextView), "Responder after pane focus restore: \(String(describing: window.firstResponder))")
        #expect(field.currentEditor() == nil)
    }
}
