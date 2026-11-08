import Foundation

/// Case-insensitive subsequence matching for the command palette and search.
enum FuzzyMatch {
    /// Higher is better; nil when `query` is not a subsequence of `label`. Prefixes beat
    /// substrings, which beat scattered matches; adjacent and word-initial hits score extra.
    static func score(_ query: String, in label: String) -> Int? {
        let needle = Array(query.lowercased())
        let haystack = Array(label.lowercased())
        if needle.isEmpty { return 0 }
        if haystack.starts(with: needle) { return 10_000 - haystack.count }
        if let start = substringStart(needle, in: haystack) { return 5_000 - start * 10 - haystack.count }

        var score = 0
        var searchFrom = 0
        var previous = -2
        for character in needle {
            guard let found = haystack[searchFrom...].firstIndex(of: character) else { return nil }
            score += found == previous + 1 ? 10 : 1
            if found == 0 || haystack[found - 1] == " " {
                score += 5
            }
            previous = found
            searchFrom = found + 1
        }
        return score
    }

    /// `items` whose `label` matches `query`, best first; stable for equal scores. An empty query
    /// returns everything unchanged.
    static func filter<T>(_ items: [T], query: String, label: KeyPath<T, String>) -> [T] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return items }
        return items.enumerated()
            .compactMap { index, item in
                score(trimmed, in: item[keyPath: label]).map { Scored(index: index, item: item, score: $0) }
            }
            .sorted { a, b in a.score != b.score ? a.score > b.score : a.index < b.index }
            .map(\.item)
    }

    private static func substringStart(_ needle: [Character], in haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return start
        }
        return nil
    }

    private struct Scored<T> {
        var index: Int
        var item: T
        var score: Int
    }
}
