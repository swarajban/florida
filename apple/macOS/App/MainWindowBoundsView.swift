import AppKit
import FloridaKit
import SwiftUI

struct MainWindowBoundsView: NSViewRepresentable {
    static var defaultContentSize: CGSize {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return CGSize(width: 1240, height: 820)
        }
        let content = NSWindow.contentRect(
            forFrameRect: screen.visibleFrame, styleMask: [.titled, .closable, .miniaturizable, .resizable])
        return WindowBounds.clamped(
            CGRect(origin: content.origin, size: CGSize(width: 1240, height: 820)), to: content).size
    }

    func makeNSView(context: Context) -> MainWindowBoundsHostView {
        MainWindowBoundsHostView()
    }

    func updateNSView(_ nsView: MainWindowBoundsHostView, context: Context) {
        nsView.constrainWindow()
    }
}

final class MainWindowBoundsHostView: NSView {
    private weak var observedWindow: NSWindow?
    private var observers: [any NSObjectProtocol] = []
    private var isClamping = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard observedWindow !== window else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        observedWindow = window
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification, NSWindow.didResizeNotification] {
            observe(name, object: window)
        }
        observe(NSApplication.didChangeScreenParametersNotification, object: nil)
        constrainWindow()
        DispatchQueue.main.async { [weak self] in self?.constrainWindow() }
    }

    func constrainWindow() {
        guard !isClamping, let window,
              !window.styleMask.contains(.fullScreen), !window.isMiniaturized,
              let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        isClamping = true
        defer { isClamping = false }
        let visible = screen.visibleFrame
        window.minSize = CGSize(
            width: min(window.minSize.width, visible.width), height: min(window.minSize.height, visible.height))
        window.maxSize = visible.size
        let frame = WindowBounds.clamped(window.frame, to: visible)
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    private func observe(_ name: Notification.Name, object: AnyObject?) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.constrainWindow() }
        })
    }
}
