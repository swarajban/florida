import Foundation

public struct ShareInput: Hashable, Sendable {
    public var url: String?
    public var pageTitle: String?
    public var text: String?

    public init(url: String? = nil, pageTitle: String? = nil, text: String? = nil) {
        self.url = url
        self.pageTitle = pageTitle
        self.text = text
    }
}

public enum ShareDraftParser {
    public static func parse(_ input: ShareInput, now: Date, calendar: Calendar) -> QuickAddDraft? {
        let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pageTitle = input.pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var source = input.url.flatMap { TaskSource.from(url: $0) }
            ?? text.split(whereSeparator: \.isWhitespace).lazy.compactMap { TaskSource.from(url: String($0)) }.first
        guard source != nil || !text.isEmpty else { return nil }
        if let selected = source, !pageTitle.isEmpty {
            source = TaskSource.from(url: selected.url, title: pageTitle) ?? selected
        }

        let body = pageTitle.isEmpty ? text : pageTitle
        let lines = body.components(separatedBy: .newlines)
        let firstLine = lines.first ?? ""
        var draft = QuickAddParser.parse(firstLine, now: now, calendar: calendar, source: source)
        if lines.count > 1 {
            let remainder = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty { draft.notes = [draft.notes, remainder].compactMap { $0 }.joined(separator: "\n") }
        } else if body.count > 120 {
            draft.title = String(draft.title.prefix(120))
            draft.notes = body
        }
        if draft.title.isEmpty { draft.title = firstLine.isEmpty ? source?.title ?? "" : firstLine }
        guard !draft.title.isEmpty else { return nil }
        return draft
    }
}
