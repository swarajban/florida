import AppKit
import FloridaKit
import SwiftUI

struct TaskPaneSearch: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TaskPaneSearchField {
        let field = TaskPaneSearchField()
        let placeholder = "Search tasks, waiting on, or #tag"
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.setAccessibilityIdentifier("task-pane-search")
        field.delegate = context.coordinator
        field.isEditable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        return field
    }

    func updateNSView(_ field: TaskPaneSearchField, context: Context) {
        context.coordinator.text = $text
        field.isEnabled = context.environment.isEnabled
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>?

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text?.wrappedValue = field.stringValue
        }
    }
}

final class TaskPaneSearchField: NSTextField {
    private var handlingClick = false

    override func becomeFirstResponder() -> Bool {
        if !handlingClick {
            guard let event = NSApp.currentEvent, event.window === window, event.type == .keyDown,
                  let chord = KeyChord(event: event), chord == KeyChord("tab") || chord == KeyChord("tab", [.shift])
            else { return false }
        }
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        focusForClick { super.mouseDown(with: event) }
    }

    func focusForClick(perform: () -> Void = {}) {
        handlingClick = true
        defer { handlingClick = false }
        if isEnabled, currentEditor() == nil { window?.makeFirstResponder(self) }
        perform()
    }

    static func editing(in window: NSWindow) -> TaskPaneSearchField? {
        (window.firstResponder as? NSTextView)?.delegate as? TaskPaneSearchField
    }

    func handleKey(_ chord: KeyChord?) -> Bool? {
        guard chord == KeyChord("escape") || chord == KeyChord("return") else { return nil }
        guard let editor = currentEditor() as? NSTextView, !editor.hasMarkedText() else { return false }
        return window?.makeFirstResponder(nil) == true
    }

    func releaseFocusIfOutside(_ locationInWindow: NSPoint) {
        if !bounds.contains(convert(locationInWindow, from: nil)) {
            window?.makeFirstResponder(nil)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willBeginSheetNotification, object: window)
            if currentEditor() != nil { window.makeFirstResponder(nil) }
        }
        super.viewWillMove(toWindow: newWindow)
        if let newWindow {
            NotificationCenter.default.addObserver(
                self, selector: #selector(sheetWillBegin), name: NSWindow.willBeginSheetNotification, object: newWindow
            )
        }
    }

    @objc private func sheetWillBegin(_ notification: Notification) {
        if currentEditor() != nil { window?.makeFirstResponder(nil) }
    }
}
