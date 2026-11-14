import AppKit
import FloridaKit
import SwiftUI

/// An invisible view that installs one local key-down monitor for the window it lives in and
/// hands every event to `AppModel.handleKeyDown` before AppKit dispatches it. Events the model
/// consumes are swallowed (nil); the rest continue to menus and text fields. Events from other
/// windows (Settings) are ignored so their text fields and menu shortcuts behave normally.
///
/// An event's detail popover is a window of its own, so it carries a second copy with
/// `isEventPopover` set: the keys that act on the open event work while the popover has the
/// keyboard.
struct KeyEventMonitorView: NSViewRepresentable {
    let model: AppModel
    var isEventPopover = false

    func makeNSView(context: Context) -> KeyMonitorHostView {
        let view = KeyMonitorHostView()
        view.isEventPopover = isEventPopover
        view.install(model: model)
        return view
    }

    func updateNSView(_ nsView: KeyMonitorHostView, context: Context) {
        nsView.install(model: model)
    }
}

/// The monitor lives exactly as long as the view is in a window: `NSView` is main-actor isolated
/// and `deinit` is not, so Swift 6 forbids touching `monitor` there; `viewDidMoveToWindow` runs
/// on the main actor at both ends of the view's life in a window.
final class KeyMonitorHostView: NSView {
    private var monitor: Any?
    private let box = MonitorBox()
    /// Set before the view enters a window, for the copy in an event's detail popover: its
    /// window is not the main window, and only the open event's keys run from it.
    var isEventPopover = false

    func install(model: AppModel) {
        box.model = model
        box.view = self
        if let window {
            if !isEventPopover {
                model.mainWindow = window
            }
            startMonitoring()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else {
            if !isEventPopover {
                box.model?.mainWindow = window
            }
            startMonitoring()
        }
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        let box = box
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            let handled = MainActor.assumeIsolated {
                box.view?.handle(event) ?? false
            }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let model = box.model, let window else { return false }
        let trace = [UInt16(5), 17, 31, 53].contains(event.keyCode)
        if trace {
            InboxUIDiagnostic.record("monitor event=\(event.type.rawValue) code=\(event.keyCode) flags=\(event.modifierFlags.rawValue) repeat=\(event.isARepeat) ownWindow=\(event.window === window) keyWindow=\(window.isKeyWindow) popover=\(isEventPopover) responder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        }
        if event.type == .keyUp {
            model.shortcutRepeats.gate.keyUp(keyCode: event.keyCode)
            return false
        }
        if model.shortcutRepeats.gate.keyDown(keyCode: event.keyCode, isRepeat: event.isARepeat) {
            if trace { InboxUIDiagnostic.record("monitor.repeat.swallowed code=\(event.keyCode)") }
            return true
        }
        guard event.window === window else { return false }
        guard !SelectorInput.isEditing(in: window) else {
            if trace { InboxUIDiagnostic.record("monitor.selector.editing code=\(event.keyCode)") }
            return false
        }
        let chord = KeyChord(event: event)
        let allowsRepeat = model.jump == nil && chord.map(ShortcutKeyRepeat.isNavigation) == true
        let handled = model.handleKeyDown(event, inEventPopover: isEventPopover)
        if trace { InboxUIDiagnostic.record("monitor.handled code=\(event.keyCode) result=\(handled)") }
        if handled, !allowsRepeat {
            model.shortcutRepeats.gate.didHandle(keyCode: event.keyCode)
        }
        return handled
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

/// Weak references the monitor closure may capture whatever its isolation; they are only read
/// on the main actor.
private final class MonitorBox: @unchecked Sendable {
    weak var model: AppModel?
    weak var view: KeyMonitorHostView?
}
