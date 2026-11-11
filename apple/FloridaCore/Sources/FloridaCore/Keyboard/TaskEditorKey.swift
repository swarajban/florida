import Foundation

/// A control of the Mac task editor and the key that reaches it. The editor shows each key beside
/// its control and routes key presses through `press(for:focus:)`, so the two cannot disagree.
///
/// The keys are the editor's own: the sheet has the keyboard to itself, so `s` is Start here and
/// Snooze on the calendar.
public enum TaskEditorKey: String, CaseIterable, Hashable, Sendable {
    case markDone, title, notes, start, due, deadline, category, duration, priority, context, project
    case attention, pinnedStart

    /// What has the keyboard in the editor when a key arrives.
    public enum Focus: Hashable, Sendable {
        /// Nothing: every key acts.
        case none
        /// A text field, which takes every key itself.
        case text
        /// A date field. It takes `a` and `p` (AM and PM) and Space; the other keys still act, so
        /// `s` then `d` goes from one date to the other.
        case date
        /// Another control (a button or a menu reached with Tab), which Space presses.
        case control
    }

    /// A key press that reaches a control.
    public struct Press: Hashable, Sendable {
        public let key: TaskEditorKey
        /// Shift was held: a choice steps backward, a date is switched off.
        public let isShifted: Bool

        public init(key: TaskEditorKey, isShifted: Bool = false) {
            self.key = key
            self.isShifted = isShifted
        }
    }

    /// The key, as `KeyChord.key` names it.
    public var key: String {
        switch self {
        case .markDone: "space"
        case .title: "t"
        case .notes: "n"
        case .start: "s"
        case .due: "d"
        case .deadline: "h"
        case .category: "c"
        case .duration: "m"
        case .priority: "p"
        case .context: "o"
        case .project: "j"
        case .attention: "a"
        case .pinnedStart: "i"
        }
    }

    /// The key as its keycap shows it: "D", "space".
    public var keycap: String {
        key.count == 1 ? key.uppercased() : key
    }

    /// Steps through a list of choices (the key again for the next one), or holds a date that
    /// Shift switches off. The rest only put the keyboard in a field or press a button, and
    /// ignore Shift.
    public var takesShift: Bool {
        switch self {
        case .start, .due, .pinnedStart, .deadline, .category, .priority, .context, .project, .attention: true
        case .markDone, .title, .notes, .duration: false
        }
    }

    /// The control `chord` reaches while `focus` has the keyboard; nil when the key is not the
    /// editor's, or belongs to what is focused.
    public static func press(for chord: KeyChord, focus: Focus) -> Press? {
        guard focus != .text, chord.modifiers.subtracting([.shift]).isEmpty,
              let key = allCases.first(where: { $0.key == chord.key })
        else { return nil }
        let isShifted = chord.modifiers.contains(.shift)
        if isShifted, !key.takesShift { return nil }
        switch focus {
        case .none:
            break
        case .date:
            if key == .markDone || key == .attention || key == .priority { return nil }
        case .control:
            if key == .markDone { return nil }
        case .text:
            return nil
        }
        return Press(key: key, isShifted: isShifted)
    }

    /// The choice after `current` in `choices`, or before it when `backward`, wrapping at both
    /// ends. A `current` that is not among them (a deleted project) steps onto the first.
    public static func step<Choice: Equatable>(_ current: Choice, in choices: [Choice], backward: Bool) -> Choice {
        guard let index = choices.firstIndex(of: current) else { return choices.first ?? current }
        let next = (index + (backward ? choices.count - 1 : 1)) % choices.count
        return choices[next]
    }
}
