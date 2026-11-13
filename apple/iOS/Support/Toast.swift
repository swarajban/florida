import FloridaKit
import Foundation

/// The short message at the bottom of the screen after a row action: "Completed …" with Undo,
/// or a local write that failed.
struct Toast: Identifiable, Equatable {
    enum Style: Equatable {
        case info, success, error
    }

    let id = UUID()
    var message: String
    var systemImage: String
    var style: Style
    /// What Undo puts back; no Undo button when nil.
    var undo: TaskUndo?
    /// Ghost blocks the action added, which Undo removes.
    var ghostIds: [String] = []
}
