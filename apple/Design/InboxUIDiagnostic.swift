import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum InboxUIDiagnostic {
    static var enabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "demoData") && UserDefaults.standard.bool(forKey: "uiTraceInbox")
        #else
        false
        #endif
    }

    static func record(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        NSLog("INBOX_UI_TRACE t=%.6f %@", ProcessInfo.processInfo.systemUptime, message())
    }

    #if canImport(UIKit)
    static func samplePresentation(_ boundary: String) {
        guard enabled else { return }
        for delay in [0, 1, 5, 15] {
            Task { @MainActor in
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                let start = ProcessInfo.processInfo.systemUptime
                record("presentation.sample boundary=\(boundary) delay=\(delay)")
                for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                    for window in scene.windows {
                        record("window class=\(type(of: window)) key=\(window.isKeyWindow) hidden=\(window.isHidden) scene=\(scene.activationState)")
                        recordResponders(in: window)
                        var remaining = 100
                        recordAnimations(in: window.layer, depth: 0, remaining: &remaining)
                    }
                }
                record("presentation.sample.end elapsed=\(ProcessInfo.processInfo.systemUptime - start)")
            }
        }
    }

    private static func recordResponders(in view: UIView) {
        if view.isFirstResponder {
            record("responder class=\(type(of: view)) hidden=\(view.isHidden) alpha=\(view.alpha) frame=\(view.frame)")
        }
        if let control = view as? UISwitch, let window = control.window {
            let center = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: window)
            let hit = window.hitTest(center, with: nil)
            record("switch on=\(control.isOn) enabled=\(control.isEnabled) interaction=\(control.isUserInteractionEnabled) hidden=\(control.isHidden) alpha=\(control.alpha) center=\(center) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") ownsHit=\(hit === control || hit?.isDescendant(of: control) == true)")
        }
        for child in view.subviews { recordResponders(in: child) }
    }

    private static func recordAnimations(in layer: CALayer, depth: Int, remaining: inout Int) {
        guard remaining > 0 else { return }
        for key in layer.animationKeys() ?? [] {
            guard remaining > 0, let animation = layer.animation(forKey: key) else { continue }
            remaining -= 1
            record("animation layer=\(type(of: layer)) delegate=\(String(describing: layer.delegate.map { type(of: $0) })) depth=\(depth) key=\(key) duration=\(animation.duration) repeat=\(animation.repeatCount) repeatDuration=\(animation.repeatDuration) speed=\(animation.speed) begin=\(animation.beginTime) removed=\(animation.isRemovedOnCompletion)")
        }
        for child in layer.sublayers ?? [] {
            recordAnimations(in: child, depth: depth + 1, remaining: &remaining)
        }
    }
    #endif
}
