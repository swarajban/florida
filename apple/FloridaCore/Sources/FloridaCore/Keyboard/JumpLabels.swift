import Foundation

/// The keys jump mode labels items with.
public enum JumpAlphabet {
    /// The home row first, then the rows above and below it, then the digits.
    public static let standard: [Character] = Array("asdfghjklqwertyuiopzxcvbnm1234567890")

    /// `count` labels over `alphabet`, whose keys must differ: one key each while the alphabet
    /// lasts. Past that, just enough keys from its end become the first key of two-key labels, so
    /// no label is the start of another and a label is complete the moment its last key is typed.
    /// Two keys reach the alphabet's size squared; a larger `count` gets that many labels.
    public static func labels(count: Int, alphabet: [Character] = standard) -> [String] {
        let size = alphabet.count
        guard count > 0, size > 0 else { return [] }
        // A key used as a prefix gives up its own label and adds `size` two-key ones.
        let prefixCount = (0...size).first { size - $0 + $0 * size >= count } ?? size
        let singles = alphabet.prefix(size - prefixCount).map { String($0) }
        let doubles = alphabet.suffix(prefixCount).flatMap { first in alphabet.map { "\(first)\($0)" } }
        return Array((singles + doubles).prefix(count))
    }
}

/// Jump mode: one key overlays a short label on every item on screen, and typing a label selects
/// its item. Holds the labels and narrows them as keys arrive.
public struct JumpLabels<Item: Hashable & Sendable>: Sendable {
    public enum Result: Hashable, Sendable {
        /// The keys typed so far spell this item's label.
        case selected(Item)
        /// Several labels start with the keys typed so far; `remaining` has narrowed to them.
        case pending
        /// No label starts with them; `remaining` is unchanged.
        case unmatched
    }

    /// What is left to type for each item the keys so far still match.
    public private(set) var remaining: [Item: String]

    /// Labels `items` in order, so the first ones get the easiest keys. An item listed twice keeps
    /// the label of its first place: something shown in two panes reads the same in both. Items
    /// past what two keys can reach get no label.
    public init(items: [Item], alphabet: [Character] = JumpAlphabet.standard) {
        var seen: Set<Item> = []
        let unique = items.filter { seen.insert($0).inserted }
        let labels = JumpAlphabet.labels(count: unique.count, alphabet: alphabet)
        remaining = Dictionary(uniqueKeysWithValues: zip(unique, labels))
    }

    public var isEmpty: Bool { remaining.isEmpty }

    /// One more key, compared without case.
    public mutating func type(_ key: String) -> Result {
        let key = key.lowercased()
        guard !key.isEmpty else { return .unmatched }
        var narrowed: [Item: String] = [:]
        for (item, label) in remaining where label.hasPrefix(key) {
            let rest = String(label.dropFirst(key.count))
            // No label is the start of another, so nothing else can match this far.
            if rest.isEmpty { return .selected(item) }
            narrowed[item] = rest
        }
        guard !narrowed.isEmpty else { return .unmatched }
        remaining = narrowed
        return .pending
    }
}

/// The stretch of a scrolling view that is on screen, top to bottom, in the same coordinates as
/// what is measured against it. Jump mode labels only what is on screen: a label nobody can see
/// uses up a key.
public struct JumpViewport: Hashable, Sendable {
    public var top: Double
    public var bottom: Double

    public init(top: Double, bottom: Double) {
        self.top = top
        self.bottom = bottom
    }

    /// Whether a label with one fixed place, from `top` to `bottom` (a list row's), is all on
    /// screen.
    public func shows(top: Double, bottom: Double) -> Bool {
        top >= self.top && bottom <= self.bottom
    }

    /// Where the top of a `labelHeight`-point label goes on something that runs from `top` to
    /// `bottom` and can carry it anywhere down its length (a calendar block): at its own top when
    /// that is on screen, else at the top of the viewport. Nil when the part on screen is too
    /// short for the label; something shorter than the label has to be on screen whole.
    public func labelTop(onItemFrom top: Double, to bottom: Double, labelHeight: Double) -> Double? {
        let visibleTop = max(top, self.top)
        let visibleBottom = min(bottom, self.bottom)
        guard visibleBottom - visibleTop >= min(labelHeight, bottom - top) else { return nil }
        return visibleTop
    }
}
