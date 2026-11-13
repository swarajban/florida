import AppKit
import SwiftUI

struct SelectorInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let identifier: String
    let command: (String) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SelectorTextField {
        let field = SelectorTextField()
        field.placeholderString = placeholder
        field.setAccessibilityIdentifier(identifier)
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 14)
        return field
    }

    func updateNSView(_ field: SelectorTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    static func isEditing(in window: NSWindow) -> Bool {
        SelectorWindowHost.counts[ObjectIdentifier(window), default: 0] > 0
            || (window.firstResponder as? NSTextView)?.delegate is SelectorTextField
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SelectorInput

        init(_ parent: SelectorInput) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
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
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
        }
    }
}
