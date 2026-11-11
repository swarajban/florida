import AppKit
import SwiftUI

extension View {
    /// Runs `action` on every click, the moment it lands, saying whether it is the second click
    /// of a double-click. A double-click so runs it twice: once to select, once to open.
    ///
    /// Use this where a click selects and a double-click opens. `.onTapGesture(count: 2)` beside
    /// `.onTapGesture` makes SwiftUI hold every single click until the double-click interval has
    /// passed, in case a second one follows: the selection then lags by up to half a second.
    func onClick(_ action: @escaping @MainActor (_ isDouble: Bool) -> Void) -> some View {
        onTapGesture { action(Clicks.isDouble) }
    }

    /// `onClick` with the click's place in this view.
    func onClickAt(_ action: @escaping @MainActor (_ point: CGPoint, _ isDouble: Bool) -> Void) -> some View {
        onTapGesture { point in action(point, Clicks.isDouble) }
    }
}

@MainActor
enum Clicks {
    /// The click being handled is the second of a double-click. A third click is a single one
    /// again, so a triple-click does not open twice.
    static var isDouble: Bool {
        NSApp.currentEvent?.clickCount == 2
    }
}
