import Foundation

public enum SelectorSearch {
    public static func rankedIndices(in labels: [String], query: String, preservingOrder: Bool = false) -> [Int] {
        let locale = Locale(identifier: "en_US_POSIX")
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        guard !query.isEmpty else { return Array(labels.indices) }

        var prefixes: [Int] = []
        var substrings: [Int] = []
        var subsequences: [Int] = []
        for (index, label) in labels.enumerated() {
            let label = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            if label.hasPrefix(query) {
                prefixes.append(index)
            } else if label.contains(query) {
                substrings.append(index)
            } else {
                var next = query.startIndex
                for character in label where character == query[next] {
                    next = query.index(after: next)
                    if next == query.endIndex { break }
                }
                if next == query.endIndex { subsequences.append(index) }
            }
        }
        let matches = prefixes + substrings + subsequences
        return preservingOrder ? matches.sorted() : matches
    }
}
