import Foundation

/// Event descriptions as text with live links. Google stores descriptions as plain text or as a
/// small subset of HTML (`<a href>`, `<br>`, `<p>`, `<ul><li>`, `<b>`); the HTML is reduced to
/// text, its anchors become links, and bare URLs, emails and phone numbers are linked as well.
enum RichText {
    static func attributed(_ raw: String) -> AttributedString {
        var result = AttributedString()
        for segment in segments(raw) {
            var piece = AttributedString(segment.text)
            if let href = segment.href, let url = URL(string: href) {
                piece.link = url
            }
            result.append(piece)
        }
        linkify(&result)
        return result
    }

    struct Segment: Equatable {
        var text: String
        var href: String?
    }

    /// The description split into text and anchor runs, with tags removed and entities decoded.
    static func segments(_ raw: String) -> [Segment] {
        guard raw.range(of: #"<[a-zA-Z/][^>]*>"#, options: .regularExpression) != nil else {
            return [Segment(text: raw)]
        }
        let anchor = try? NSRegularExpression(
            pattern: #"<a\s[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators])
        let source = raw as NSString
        var segments: [Segment] = []
        var cursor = 0
        for match in anchor?.matches(in: raw, range: NSRange(location: 0, length: source.length)) ?? [] {
            let before = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            segments.append(Segment(text: plainText(fromHTML: before)))
            let href = decodeEntities(source.substring(with: match.range(at: 1)))
            let label = plainText(fromHTML: source.substring(with: match.range(at: 2)))
            segments.append(Segment(text: label.isEmpty ? href : label, href: href))
            cursor = match.range.location + match.range.length
        }
        segments.append(Segment(text: plainText(fromHTML: source.substring(from: cursor))))
        if var last = segments.popLast() {
            last.text = String(last.text.reversed().drop(while: \.isWhitespace).reversed())
            segments.append(last)
        }
        return segments.filter { !$0.text.isEmpty }
    }

    /// Line breaks for block tags, bullets for list items, no other tags, decoded entities.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        let replacements: [(String, String)] = [
            (#"<br\s*/?>"#, "\n"), (#"</(p|div|li|ul|ol|h\d)\s*>"#, "\n"), (#"<li[^>]*>"#, "• "), (#"<[^>]+>"#, ""),
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(
                of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return decodeEntities(text)
    }

    /// The named entities Google uses, in replacement order: `&amp;` last, so that an escaped
    /// entity such as `&amp;lt;` decodes once, to `&lt;`.
    private static let entities: [(String, String)] = [
        ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&"),
    ]

    static func decodeEntities(_ text: String) -> String {
        var text = text
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }

    /// Adds links for URLs, emails and phone numbers that are not inside a link already.
    private static func linkify(_ text: inout AttributedString) {
        #if canImport(Darwin)
        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return }
        let plain = String(text.characters)
        for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let range = Range<AttributedString.Index>(match.range, in: text), text[range].link == nil else { continue }
            if let url = match.url {
                text[range].link = url
            } else if let phone = match.phoneNumber, let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
                text[range].link = url
            }
        }
        #endif
    }
}
