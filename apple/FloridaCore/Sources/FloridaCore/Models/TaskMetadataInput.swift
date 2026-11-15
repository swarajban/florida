import Foundation

extension TaskItem {
    public static func tagsFromInput(_ input: String) -> [String] {
        input.split { $0.isWhitespace || $0 == "," }.map {
            String($0.drop(while: { $0 == "#" }))
        }
    }

    public func matchesMetadataSearch(_ query: String, waitingOnly: Bool = false) -> Bool {
        guard !waitingOnly || isWaiting else { return false }
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            let text = String(term)
            if text.hasPrefix("#") {
                return tags.contains { $0.localizedCaseInsensitiveCompare(String(text.dropFirst())) == .orderedSame }
            }
            return [title, notes ?? "", waitingOn ?? ""].contains { $0.localizedCaseInsensitiveContains(text) }
                || tags.contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }
}
