import SwiftUI
import UIKit

/// Hold a block for a moment, then drag it. A UIKit long press rather than SwiftUI's
/// `LongPressGesture.sequenced(before: DragGesture)`: the SwiftUI pair claims the touch the
/// moment it lands, so a finger that starts on a block can never scroll the grid, while a
/// `UILongPressGestureRecognizer` lets the scroll view's pan take a finger that moves and only
/// recognizes one that holds still, the way Calendar's hold-to-move works. It also reports a
/// touch the system takes away (a call banner, an edge swipe), which SwiftUI's `onEnded` never
/// does.
///
/// `onMove` and the drop get the finger's travel since the hold completed, in points.
struct BlockMoveGesture: UIGestureRecognizerRepresentable {
    static let holdDuration: TimeInterval = 0.3
    /// How far the finger may wander during the hold before it counts as a scroll instead.
    static let allowableMovement: CGFloat = 12

    let onLift: () -> Void
    let onMove: (CGSize) -> Void
    let onDrop: (CGSize) -> Void
    let onCancel: () -> Void

    /// Where the finger was when the hold completed, in window points; `onMove`'s translation is
    /// measured from it. Window points because nothing under the finger moves while a block is
    /// lifted (the grid disables scrolling), and they need no SwiftUI geometry lookups per event.
    final class Coordinator {
        var origin: CGPoint = .zero
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = Self.holdDuration
        recognizer.allowableMovement = Self.allowableMovement
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let location = recognizer.location(in: nil)
        let origin = context.coordinator.origin
        let translation = CGSize(width: location.x - origin.x, height: location.y - origin.y)
        switch recognizer.state {
        case .began:
            context.coordinator.origin = location
            onLift()
        case .changed:
            onMove(translation)
        case .ended:
            onDrop(translation)
        case .cancelled, .failed:
            onCancel()
        default:
            break
        }
    }
}
