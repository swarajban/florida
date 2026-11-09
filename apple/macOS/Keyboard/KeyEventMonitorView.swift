import AppKit
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
        let inEventPopover = isEventPopover
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated {
                guard let window = box.view?.window, event.window === window else { return false }
                return box.model?.handleKeyDown(event, inEventPopover: inEventPopover) ?? false
            }
            return handled ? nil : event
        }
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
    weak var view: NSView?
}
