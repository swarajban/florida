public struct ShortcutKeyRepeat: Sendable {
    private var handledKeys: Set<UInt16> = []

    public init() {}

    public mutating func keyDown(keyCode: UInt16, isRepeat: Bool) -> Bool {
        if !isRepeat {
            handledKeys.remove(keyCode)
            return false
        }
        return handledKeys.contains(keyCode)
    }

    public mutating func didHandle(keyCode: UInt16) {
        handledKeys.insert(keyCode)
    }

    public mutating func keyUp(keyCode: UInt16) {
        handledKeys.remove(keyCode)
    }

    public static func isNavigation(_ chord: KeyChord) -> Bool {
        chord.modifiers.isSubset(of: [.shift])
            && ["h", "j", "k", "l", "[", "]", "up", "down", "left", "right"].contains(chord.key)
    }
}
