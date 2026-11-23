import Foundation

public struct QuickAddCompletionSession: Sendable {
    private var dismissedText: String?
    private var dismissedSelection: NSRange?

    public init() {}

    public func isDismissed(in text: String, selection: NSRange) -> Bool {
        dismissedSelection == selection && dismissedText?.utf16.elementsEqual(text.utf16) == true
    }

    public mutating func dismiss(in text: String, selection: NSRange) {
        dismissedText = text
        dismissedSelection = selection
    }

    public mutating func inputChanged(to text: String) {
        if let dismissedText, !dismissedText.utf16.elementsEqual(text.utf16) {
            self = Self()
        }
    }

    public func suggestions(
        in text: String, selection: NSRange, categories: [TaskCategory], includeCategoryCreation: Bool = false
    ) -> [QuickAddSuggestion] {
        guard selection.length == 0, !isDismissed(in: text, selection: selection) else { return [] }
        return QuickAddCompletion.suggestions(
            in: text, caretUTF16: selection.location, categories: categories, includeCategoryCreation: includeCategoryCreation)
    }
}

public struct QuickAddSuggestion: Hashable, Sendable, Identifiable {
    public let id: String
    public let symbol: String
    public let title: String
    public let replacement: String
    public let replacementRange: NSRange
    public let categoryId: String?
    public internal(set) var categoryToCreate: String? = nil
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

    public static func insertTrigger(_ symbol: String, in text: String, selection: NSRange) -> Result? {
        guard let range = Range(selection, in: text) else { return nil }
        var anchor = range.lowerBound
        if symbol == "//" {
            if QuickAddScanner.splitNotes(text).body.endIndex != text.endIndex {
                return Result(text: text, caretUTF16: text.utf16.count)
            }
            anchor = text.endIndex
        } else if anchor < text.endIndex, !text[anchor].isWhitespace {
            while anchor > text.startIndex, !text[text.index(before: anchor)].isWhitespace {
                anchor = text.index(before: anchor)
            }
        }
        let leading = anchor > text.startIndex && !text[text.index(before: anchor)].isWhitespace ? " " : ""
        let trailing = anchor < text.endIndex && !text[anchor].isWhitespace ? " " : ""
        let offset = NSRange(text.startIndex..<anchor, in: text).length
        return Result(
            text: text.replacingCharacters(in: anchor..<anchor, with: leading + symbol + trailing),
            caretUTF16: offset + leading.utf16.count + symbol.utf16.count)
    }

    public static func bareCategoryTrigger(in text: String) -> Range<String.Index>? {
        let body = QuickAddScanner.splitNotes(text).body
        guard let token = body.split(whereSeparator: \.isWhitespace).first(where: { $0 == "#" }) else { return nil }
        return token.startIndex..<token.endIndex
    }

    public static func removeBareCategoryTrigger(in text: String) -> Result? {
        guard let token = bareCategoryTrigger(in: text) else { return nil }
        var range = token
        if range.upperBound < text.endIndex, text[range.upperBound].isWhitespace {
            range = range.lowerBound..<text.index(after: range.upperBound)
        } else if range.lowerBound > text.startIndex {
            range = text.index(before: range.lowerBound)..<range.upperBound
        }
        return Result(
            text: text.replacingCharacters(in: range, with: ""),
            caretUTF16: NSRange(text.startIndex..<range.lowerBound, in: text).length)
    }

    public static func suggestions(
        in text: String, caretUTF16: Int, categories: [TaskCategory], includeCategoryCreation: Bool = false
    ) -> [QuickAddSuggestion] {
        guard caretUTF16 >= 0,
              let caret = Range(NSRange(location: caretUTF16, length: 0), in: text)?.lowerBound
        else { return [] }
        let tokens = text.split(whereSeparator: \.isWhitespace)
        if let notes = tokens.first(where: { $0.hasPrefix("//") || $0 == "--" }) {
            let boundary = notes.hasPrefix("//") ? text.index(notes.startIndex, offsetBy: 2) : notes.endIndex
            if caret > boundary { return [] }
        }
        guard let index = tokens.lastIndex(where: { trigger(in: $0, before: caret) != nil }) else { return [] }
        let token = tokens[index]
        guard let start = trigger(in: token, before: caret) else { return [] }
        let symbol = String(text[start])
        if symbol == "#", tokens[..<index].contains(where: { $0.hasPrefix("#") }) { return [] }
        if "#@!/&".contains(symbol), caret > token.endIndex { return [] }
        if symbol == "/", token != "/", token != "//" { return [] }
        let queryStart = symbol == "/" ? token.endIndex : text.index(after: start)
        guard queryStart <= caret else { return [] }
        var queryEnd = caret
        var end = token.endIndex
        if "^*=~".contains(symbol) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let scanner = QuickAddScanner(
                tokens: tokens.map(String.init), now: Date(timeIntervalSince1970: 0), calendar: calendar)
            if (token.count > 1 || caret > token.endIndex), let clause = scanner.symbolClause(at: index) {
                end = tokens[index + clause.consumed - 1].endIndex
                if caret > end, text[text.index(before: caret)].isWhitespace { return [] }
            }
            if let editing = tokens[index...].last(where: { $0.startIndex < caret }), editing.endIndex > end {
                end = editing.endIndex
                queryEnd = max(caret, end)
            }
        }
        let rawQuery = String(text[queryStart..<(symbol == "#" && queryEnd == queryStart ? end : queryEnd)])
        let query = normalize(rawQuery)
        if caret > token.endIndex, query.isEmpty { return [] }
        let range = NSRange(start..<end, in: text)
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
        case "&":
            choices = [
                ("parallel", "Can run in parallel", "&parallel", ["shared", "alongside"], nil),
                ("full", "Full focus", "&full", ["focus"], nil),
            ]
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
        var results = choices.filter { choice in
            query.isEmpty || ([choice.title, String(choice.value.dropFirst())] + choice.aliases)
                .contains { symbol == "#" ? categoryMatches(query, in: normalize($0)) : normalize($0).hasPrefix(query) }
        }.map { choice in
            QuickAddSuggestion(
                id: symbol + choice.id, symbol: symbol == "/" ? "//" : symbol,
                title: choice.title, replacement: choice.value, replacementRange: range,
                categoryId: choice.categoryId, sourceText: text)
        }
        if symbol == "#", includeCategoryCreation, !query.isEmpty,
           let slug = QuickAddScanner.categorySlug("#" + rawQuery), !choices.contains(where: {
            normalize($0.title) == query || normalize(String($0.value.dropFirst())) == query
        }) {
            results.append(QuickAddSuggestion(
                id: "create-category", symbol: "#", title: slug,
                replacement: "#" + slug, replacementRange: range, categoryId: nil,
                categoryToCreate: slug, sourceText: text))
        }
        return results
    }

    public static func complete(_ suggestion: QuickAddSuggestion, in text: String) -> Result? {
        guard suggestion.sourceText.utf16.elementsEqual(text.utf16),
              let range = Range(suggestion.replacementRange, in: text) else { return nil }
        var replacement = suggestion.replacement
        if suggestion.symbol == "#", range.lowerBound > text.startIndex,
           !text[text.index(before: range.lowerBound)].isWhitespace {
            replacement = " " + replacement
        }
        var caret = suggestion.replacementRange.location + replacement.utf16.count
        if range.upperBound < text.endIndex, text[range.upperBound].isWhitespace {
            caret += String(text[range.upperBound]).utf16.count
        } else {
            replacement += " "
            caret += 1
        }
        return Result(text: text.replacingCharacters(in: range, with: replacement), caretUTF16: caret)
    }

    private static func trigger(in token: Substring, before caret: String.Index) -> String.Index? {
        guard token.startIndex < caret else { return nil }
        if let first = token.first, "#@^!*=~/&".contains(first) { return token.startIndex }
        guard caret <= token.endIndex, let hash = token.firstIndex(of: "#"), hash < caret,
              token[..<hash].count >= 2, token[..<hash].allSatisfy({ $0.isLetter || $0.isNumber }),
              token[token.index(after: hash)...].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return hash
    }

    private static func categoryMatches(_ query: String, in name: String) -> Bool {
        var remaining = query.filter { !$0.isWhitespace }[...]
        guard !remaining.isEmpty else { return true }
        for character in name where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return false
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
