import Foundation

public struct QuickAddSuggestion: Hashable, Sendable, Identifiable {
    public let id: String
    public let symbol: String
    public let title: String
    public let replacement: String
    public let replacementRange: NSRange
    public let categoryId: String?
    let sourceText: String
}

public enum QuickAddCompletion {
    public static func category(explicitID: String?, hint: String?, categories: [TaskCategory]) -> TaskCategory? {
        let live = categories.filter { $0.deletedAt == nil }
        if let explicitID { return live.first { $0.id == explicitID } }
        if let hint, !normalize(hint).isEmpty {
            let query = normalize(hint)
            if let match = live.first(where: { normalize($0.name) == query })
                ?? live.first(where: { normalize($0.name).hasPrefix(query) }) {
                return match
            }
        }
        return live.first(where: \.isInbox) ?? live.first
    }

    public struct Result: Hashable, Sendable {
        public let text: String
        public let caretUTF16: Int
    }

    public static func suggestions(
        in text: String, caretUTF16: Int, categories: [TaskCategory]
    ) -> [QuickAddSuggestion] {
        guard caretUTF16 >= 0,
              let caret = Range(NSRange(location: caretUTF16, length: 0), in: text)?.lowerBound
        else { return [] }
        let tokens = text.split(whereSeparator: \.isWhitespace)
        if let notes = tokens.first(where: { $0.hasPrefix("//") || $0 == "--" }) {
            let boundary = notes.hasPrefix("//") ? text.index(notes.startIndex, offsetBy: 2) : notes.endIndex
            if caret > boundary { return [] }
        }
        guard let index = tokens.lastIndex(where: { token in
            token.startIndex < caret && token.first.map { "#@^!*=~/".contains($0) } == true
        }) else { return [] }
        let token = tokens[index]
        let symbol = String(token.prefix(1))
        if symbol == "#", tokens[..<index].contains(where: { $0.hasPrefix("#") }) { return [] }
        if "#@!/".contains(symbol), caret > token.endIndex { return [] }
        if symbol == "/", token != "/", token != "//" { return [] }
        let queryStart = symbol == "/" ? token.endIndex : text.index(after: token.startIndex)
        guard queryStart <= caret else { return [] }
        let query = normalize(String(text[queryStart..<caret]))
        var end = token.endIndex
        if "^*=~".contains(symbol) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let scanner = QuickAddScanner(
                tokens: tokens.map(String.init), now: Date(timeIntervalSince1970: 0), calendar: calendar)
            if let clause = scanner.symbolClause(at: index) {
                end = tokens[index + clause.consumed - 1].endIndex
                if caret > end, text[text.index(before: caret)].isWhitespace { return [] }
            }
            if let editing = tokens[index...].first(where: { $0.startIndex <= caret && caret <= $0.endIndex }) {
                end = max(end, editing.endIndex)
            }
        }
        let range = NSRange(token.startIndex..<end, in: text)
        let choices: [(id: String, title: String, value: String, aliases: [String], categoryId: String?)]
        switch symbol {
        case "#":
            choices = categories.filter { $0.deletedAt == nil }.inListOrder().map {
                let slug = $0.name.split { character in
                    !((character.isASCII && (character.isLetter || character.isNumber)) || character == "_" || character == "-")
                }.joined(separator: "-")
                return ($0.id, $0.name, "#" + (slug.isEmpty ? "category" : slug), [], $0.id)
            }
        case "@":
            choices = TaskContext.allCases.map { ($0.rawValue, $0.rawValue.capitalized, "@" + $0.rawValue, [], nil) }
        case "^", "~":
            let dates = [
                ("today", "Today"), ("tomorrow", "Tomorrow"), ("mon", "Monday"),
                ("tue", "Tuesday"), ("wed", "Wednesday"), ("thu", "Thursday"),
                ("fri", "Friday"), ("sat", "Saturday"), ("sun", "Sunday"),
                ("next week", "Next week"), ("eow", "End of week"), ("in 2 weeks", "In 2 weeks"),
            ]
            choices = dates.map { ($0.0, $0.1, symbol + $0.0, [], nil) }
                + (symbol == "^" ? [("someday", "Someday", "^someday", ["someday"], nil), ("none", "Someday", "^none", ["none"], nil)] : [])
        case "!":
            choices = [
                ("1", "ASAP", "!1", ["asap", "urgent"], nil),
                ("2", "High", "!2", ["high", "h"], nil),
                ("3", "Medium", "!3", ["medium", "med", "m"], nil),
                ("4", "Low", "!4", ["low", "l"], nil),
            ]
        case "*":
            choices = [
                ("daily", "Daily", "*daily", [], nil),
                ("weekly", "Weekly", "*weekly", [], nil),
                ("every 2 weeks", "Every 2 weeks", "*every 2 weeks", [], nil),
                ("monthly", "Monthly", "*monthly", [], nil),
                ("weekdays", "Weekdays", "*weekdays", [], nil),
                ("weekends", "Weekends", "*weekends", [], nil),
                ("mon wed", "Monday and Wednesday", "*mon wed", [], nil),
            ]
        case "=":
            choices = [15, 30, 45, 60, 90, 120].map { (String($0), "\($0) minutes", "=\($0)m", $0.isMultiple(of: 60) ? ["\($0 / 60)h"] : [], nil) }
        case "/":
            choices = [("notes", "Notes", "//", [], nil)]
        default:
            return []
        }
        return choices.filter { choice in
            query.isEmpty || ([choice.title, String(choice.value.dropFirst())] + choice.aliases)
                .contains { normalize($0).hasPrefix(query) }
        }.map { choice in
            QuickAddSuggestion(
                id: symbol + choice.id, symbol: symbol == "/" ? "//" : symbol,
                title: choice.title, replacement: choice.value, replacementRange: range,
                categoryId: choice.categoryId, sourceText: text)
        }
    }

    public static func complete(_ suggestion: QuickAddSuggestion, in text: String) -> Result? {
        guard suggestion.sourceText == text,
              let range = Range(suggestion.replacementRange, in: text) else { return nil }
        var replacement = suggestion.replacement
        var caret = suggestion.replacementRange.location + replacement.utf16.count
        if range.upperBound < text.endIndex, text[range.upperBound].isWhitespace {
            caret += String(text[range.upperBound]).utf16.count
        } else {
            replacement += " "
            caret += 1
        }
        return Result(text: text.replacingCharacters(in: range, with: replacement), caretUTF16: caret)
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
