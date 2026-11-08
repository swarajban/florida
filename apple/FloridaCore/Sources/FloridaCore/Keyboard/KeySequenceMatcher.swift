import Foundation

/// Feeds chords one at a time and resolves multi-key sequences such as "g t" with a timeout.
///
/// The matcher trusts the keymap to be prefix-free (see `Keymap.validate()`): a chord sequence is
/// either a complete binding, the start of one or more longer bindings, or unknown.
public struct KeySequenceMatcher: Sendable {
    public enum Result: Hashable, Sendable {
        case matched(AppCommand)
        /// The chord extends a sequence that is still incomplete; these bindings are the candidates.
        case pending([KeyBinding])
        case unmatched
    }

    public var keymap: Keymap
    /// Longest gap allowed between two chords of one sequence, in seconds.
    public var timeout: TimeInterval
    public private(set) var pendingSequence: KeySequence = []
    private var lastChordTime: Date?

    public init(keymap: Keymap, timeout: TimeInterval = 1.0) {
        self.keymap = keymap
        self.timeout = timeout
    }

    /// `time` is when the key was pressed. A gap larger than `timeout` since the previous pending
    /// chord discards the pending sequence first. After `.matched` or `.unmatched` the pending
    /// sequence is empty; an unmatched chord is not re-interpreted as the start of a new sequence.
    public mutating func feed(_ chord: KeyChord, at time: Date) -> Result {
        if let lastChordTime, !pendingSequence.isEmpty, time.timeIntervalSince(lastChordTime) > timeout {
            reset()
        }

        let candidate = pendingSequence + [chord]

        if let command = keymap.command(for: candidate) {
            reset()
            return .matched(command)
        }

        let continuations = keymap.bindings.filter {
            $0.sequence.count > candidate.count && $0.sequence.starts(with: candidate)
        }
        if !continuations.isEmpty {
            pendingSequence = candidate
            lastChordTime = time
            return .pending(continuations)
        }

        reset()
        return .unmatched
    }

    public mutating func reset() {
        pendingSequence = []
        lastChordTime = nil
    }
}
