import Foundation

/// Turns a Google Calendar event description into display text with live links. Descriptions
/// arrive as plain text or as Google's small HTML subset (`<a>`, `<br>`, `<p>`, `<b>`, `<ul>`,
/// entities); anchors keep their target, other tags become line breaks or disappear, and bare
/// URLs in the remaining text become links too. Pure Swift regexes, fast enough to run in a view
/// body: no WebKit-backed HTML import.
enum EventText {
    static func attributed(_ raw: String) -> AttributedString {
        var result = AttributedString()
        let anchor = #/<a\s[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>/#
            .ignoresCase()
            .dotMatchesNewlines()
        var rest = Substring(raw)
        while let match = rest.firstMatch(of: anchor) {
            result += linked(plain(String(rest[..<match.range.lowerBound])))
            let label = plain(String(match.output.2)).trimmingCharacters(in: .whitespacesAndNewlines)
            let href = decodeEntities(String(match.output.1))
            var piece = AttributedString(label.isEmpty ? href : label)
            if let url = URL(string: href) {
                piece.link = url
            }
            result += piece
            rest = rest[match.range.upperBound...]
        }
        result += linked(plain(String(rest)))
        return trimmed(result)
    }

    /// Strips tags, turning block-level ones into line breaks, and decodes entities.
    static func plain(_ html: String) -> String {
        var text = html
        text = text.replacing(#/<br\s*/?>/#.ignoresCase(), with: "\n")
        text = text.replacing(#/</(p|div|li|h[1-6]|tr)>/#.ignoresCase(), with: "\n")
        text = text.replacing(#/</?(ul|ol)[^>]*>/#.ignoresCase(), with: "\n")
        text = text.replacing(#/<li[^>]*>/#.ignoresCase(), with: "• ")
        text = text.replacing(#/<[^>]+>/#, with: "")
        text = decodeEntities(text)
        text = text.replacing(#/\n{3,}/#, with: "\n\n")
        return text
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        // Last, so "&amp;lt;" becomes the literal "&lt;".
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// `text` with every bare http(s) or www URL turned into a link; trailing punctuation such
    /// as the period ending a sentence stays outside the link.
    static func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for match in text.matches(of: #/(?:https?://|www\.)[^\s<>"']+/#.ignoresCase()) {
            var end = match.range.upperBound
            while end > match.range.lowerBound, let last = text[..<end].last, ".,;:!?)]}".contains(last) {
                end = text.index(before: end)
            }
            let urlText = String(text[match.range.lowerBound..<end])
            guard let url = URL(string: urlText.lowercased().hasPrefix("www.") ? "https://" + urlText : urlText),
                  let lower = AttributedString.Index(match.range.lowerBound, within: result),
                  let upper = AttributedString.Index(end, within: result)
            else { continue }
            result[lower..<upper].link = url
        }
        return result
    }

    private static func trimmed(_ text: AttributedString) -> AttributedString {
        var text = text
        while let first = text.characters.first, first.isWhitespace {
            text.removeSubrange(text.startIndex..<text.index(afterCharacter: text.startIndex))
        }
        while let last = text.characters.last, last.isWhitespace {
            text.removeSubrange(text.index(beforeCharacter: text.endIndex)..<text.endIndex)
        }
        return text
    }
}
