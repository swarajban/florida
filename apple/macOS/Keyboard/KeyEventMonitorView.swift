import AppKit
import SwiftUI

/// An invisible view that installs one local key-down monitor for the window it lives in and
/// hands every event to `AppModel.handleKeyDown` before AppKit dispatches it. Events the model
/// consumes are swallowed (nil); the rest continue to menus and text fields. Events from other
/// windows (Settings) are ignored so their text fields and menu shortcuts behave normally.
struct KeyEventMonitorView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> KeyMonitorHostView {
        let view = KeyMonitorHostView()
        view.install(model: model)
        return view
    }

    func updateNSView(_ nsView: KeyMonitorHostView, context: Context) {
        nsView.install(model: model)
    }
}

final class KeyMonitorHostView: NSView {
    private var monitor: Any?
    private let box = MonitorBox()

    func install(model: AppModel) {
        box.model = model
        box.view = self
        guard monitor == nil else { return }
        let box = box
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated {
                guard let window = box.view?.window, event.window === window else { return false }
                return box.model?.handleKeyDown(event) ?? false
            }
            return handled ? nil : event
        }
    }

    deinit {
        if let monitor {
            MainActor.assumeIsolated {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

/// Weak references the monitor closure may capture whatever its isolation; they are only read
/// on the main actor.
private final class MonitorBox: @unchecked Sendable {
    weak var model: AppModel?
    weak var view: NSView?
}
