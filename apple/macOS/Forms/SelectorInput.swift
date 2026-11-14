import AppKit
import SwiftUI

struct SelectorInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let identifier: String
    let command: (String) -> Bool
    var isPaletteInput = false
    var caretUTF16: Int?
    var caretRevision: Int?
    var selectionChanged: ((NSRange, CGRect) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SelectorTextField {
        let field = SelectorTextField()
        field.placeholderString = placeholder
        field.setAccessibilityIdentifier(identifier)
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 14)
        field.isPaletteInput = isPaletteInput
        if isPaletteInput {
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = .systemFont(ofSize: 17)
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
        }
        return field
    }

    func updateNSView(_ field: SelectorTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        if field.stringValue != text {
            field.stringValue = text
        }
        if let caretRevision, caretRevision != context.coordinator.appliedCaretRevision {
            context.coordinator.appliedCaretRevision = caretRevision
            if let editor = field.currentEditor() as? NSTextView, let caretUTF16 {
                editor.setSelectedRange(NSRange(location: max(0, min(caretUTF16, (text as NSString).length)), length: 0))
            }
        }
    }

    static func isEditing(in window: NSWindow) -> Bool {
        SelectorWindowHost.counts[ObjectIdentifier(window), default: 0] > 0
            || ((window.firstResponder as? NSTextView)?.delegate as? SelectorTextField).map { !$0.isPaletteInput } == true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SelectorInput
        var appliedCaretRevision: Int?

        init(_ parent: SelectorInput) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            scheduleSelectionReport(field)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard parent.selectionChanged != nil,
                  let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(selectionDidChange(_:)),
                name: NSTextView.didChangeSelectionNotification, object: editor)
            scheduleSelectionReport(field)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: nil)
        }

        @objc private func selectionDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView,
                  let field = editor.delegate as? NSTextField else { return }
            scheduleSelectionReport(field)
        }

        private func scheduleSelectionReport(_ field: NSTextField) {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field else { return }
                reportSelection(field)
            }
        }

        private func reportSelection(_ field: NSTextField) {
            guard let callback = parent.selectionChanged,
                  let editor = field.currentEditor() as? NSTextView,
                  let window = field.window, !editor.hasMarkedText(), parent.text == field.stringValue else { return }
            let selection = editor.selectedRange()
            let screenRect = editor.firstRect(forCharacterRange: NSRange(location: selection.location, length: 0), actualRange: nil)
            let rect = field.convert(window.convertFromScreen(screenRect), from: nil)
            let y = field.isFlipped ? rect.maxY : field.bounds.maxY - rect.minY
            callback(selection, CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height))
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            return parent.command(NSStringFromSelector(commandSelector))
        }
    }
}

struct SelectorWindowGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> SelectorWindowHost { SelectorWindowHost() }
    func updateNSView(_ view: SelectorWindowHost, context: Context) {}
}

@MainActor
final class SelectorOrigin {
    weak var window: NSWindow?
    weak var view: NSView?

    func reveal() {
        guard let view else { return }
        _ = view.scrollToVisible(view.bounds)
    }

    static func dismissalPoint(in window: NSWindow?) -> NSPoint? {
        guard let window, let event = NSApp.currentEvent, event.window === window,
              [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(event.type) else { return nil }
        return event.locationInWindow
    }

    static func finishDismissal(in window: NSWindow?, preservingFocusAt point: NSPoint?, onDismiss: () -> Void) async {
        await Task.yield()
        if let point, let editor = window?.firstResponder as? NSTextView, editor.isEditable,
           !(editor.delegate is SelectorTextField), let content = window?.contentView {
            var hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
            while let view = hit {
                if view === editor || (view as? NSTextField)?.currentEditor() === editor { return }
                hit = view.superview
            }
        }
        window?.makeFirstResponder(nil)
        onDismiss()
    }
}

struct SelectorOriginView: NSViewRepresentable {
    let origin: SelectorOrigin

    func makeNSView(context: Context) -> SelectorOriginHost {
        let view = SelectorOriginHost()
        view.origin = origin
        return view
    }

    func updateNSView(_ view: SelectorOriginHost, context: Context) {}
}

final class SelectorOriginHost: NSView {
    var origin: SelectorOrigin?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        origin?.window = window
        origin?.view = window == nil ? nil : self
    }
}

final class SelectorWindowHost: NSView {
    static var counts: [ObjectIdentifier: Int] = [:]
    private weak var registeredWindow: NSWindow?

    static func register(_ window: NSWindow) {
        counts[ObjectIdentifier(window), default: 0] += 1
    }

    static func unregister(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        counts[id, default: 1] -= 1
        if counts[id] == 0 { counts[id] = nil }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let registeredWindow {
            Self.unregister(registeredWindow)
        }
        registeredWindow = window
        if let window { Self.register(window) }
    }
}

final class SelectorTextField: NSTextField {
    var isPaletteInput = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
            if self.isPaletteInput, let editor = self.currentEditor() as? NSTextView {
                editor.setSelectedRange(NSRange(location: (self.stringValue as NSString).length, length: 0))
            }
        }
    }
}
