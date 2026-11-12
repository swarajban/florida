import Foundation

public struct EventResource: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case googleDocs, googleSheets, googleSlides, notion, figma, github, linear, zoom, googleMeet, other
    }

    public let url: URL
    public let title: String
    public let kind: Kind
    public var id: String { url.absoluteString }

    public var kindLabel: String {
        switch kind {
        case .googleDocs: "Google Docs"
        case .googleSheets: "Google Sheets"
        case .googleSlides: "Google Slides"
        case .notion: "Notion"
        case .figma: "Figma"
        case .github: "GitHub"
        case .linear: "Linear"
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        case .other: Self.hostName(url)
        }
    }

    public static func extract(description: String?, location: String?, excluding joinURL: URL? = nil) -> [Self] {
        let excluded = joinURL.flatMap { normalizedURL(decodeEntities($0.absoluteString)) }.map(identity)
        var resources: [Self] = []
        var indices: [String: Int] = [:]
        for text in [description, location].compactMap(\.self) {
            for candidate in candidates(in: text) {
                guard let url = normalizedURL(candidate.url), identity(url) != excluded else { continue }
                let kind = kind(for: url)
                let title = readableTitle(candidate.title, url: url, kind: kind)
                let resource = Self(url: url, title: title, kind: kind)
                let key = identity(url)
                if let index = indices[key] {
                    if candidate.title != nil && resources[index].title == readableTitle(nil, url: url, kind: kind) {
                        resources[index] = resource
                    }
                } else {
                    indices[key] = resources.count
                    resources.append(resource)
                }
            }
        }
        return resources
    }

    private static func candidates(in text: String) -> [(url: String, title: String?)] {
        let anchor = #/<a\b[^>]*?\s+href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a\s*>/#
            .ignoresCase().dotMatchesNewlines()
        var result: [(url: String, title: String?)] = []
        var rest = text[...]
        while let match = rest.firstMatch(of: anchor) {
            result += bareURLs(in: String(rest[..<match.range.lowerBound]))
            let href = String(match.output.1 ?? match.output.2 ?? match.output.3 ?? "")
            let label = plain(String(match.output.4))
            result.append((decodeEntities(href), label.isEmpty ? nil : label))
            rest = rest[match.range.upperBound...]
        }
        result += bareURLs(in: String(rest))
        return result
    }

    private static func bareURLs(in text: String) -> [(url: String, title: String?)] {
        let text = plain(text)
        return text.matches(of: #/(?:https?://|www\.)[^\s<>"']+/#.ignoresCase()).map { match in
            var value = String(match.output)
            while let last = value.last {
                if ".,;:!?".contains(last) {
                    value.removeLast()
                } else if let opening = [")": "(", "]": "[", "}": "{"][String(last)],
                          value.filter({ String($0) == String(last) }).count > value.filter({ String($0) == opening }).count {
                    value.removeLast()
                } else {
                    break
                }
            }
            return (value, nil)
        }
    }

    private static func plain(_ text: String) -> String {
        decodeEntities(text.replacing(#/</?[a-zA-Z][a-zA-Z0-9]*(?:\s[^>]*)?\s*/?>/#, with: " "))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func decodeEntities(_ text: String) -> String {
        let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ",
                     "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”"]
        var result = ""
        var rest = text[...]
        for match in text.matches(of: #/&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[a-zA-Z]+);/#) {
            result += rest[..<match.range.lowerBound]
            let entity = String(match.output.1)
            var decoded = named[entity]
            if entity.hasPrefix("#") {
                let hex = entity.lowercased().hasPrefix("#x")
                if let value = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                   let scalar = UnicodeScalar(value) {
                    decoded = String(scalar)
                }
            }
            result += decoded ?? String(match.output.0)
            rest = text[match.range.upperBound...]
        }
        result += rest
        return result
    }

    private static func normalizedURL(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("www.") { value = "https://" + value }
        for _ in 0..<4 {
            guard let components = URLComponents(string: value),
                  let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = components.host?.lowercased(), !host.isEmpty,
                  components.user == nil, components.password == nil,
                  let url = components.url else { return nil }
            if ["google.com", "www.google.com"].contains(host), components.path == "/url",
               let target = components.queryItems?.first(where: { ["q", "url"].contains($0.name) })?.value {
                value = target
                continue
            }
            return url
        }
        return nil
    }

    private static func identity(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) {
            parts.port = nil
        }
        if parts.path == "/" { parts.path = "" }
        return parts.string ?? url.absoluteString
    }

    private static func kind(for url: URL) -> Kind {
        let host = url.host?.lowercased() ?? ""
        func isHost(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if host == "docs.google.com" {
            switch url.pathComponents.dropFirst().first {
            case "document": return .googleDocs
            case "spreadsheets": return .googleSheets
            case "presentation": return .googleSlides
            default: break
            }
        }
        if isHost("notion.so") || isHost("notion.site") { return .notion }
        if isHost("figma.com") { return .figma }
        if isHost("github.com") { return .github }
        if isHost("linear.app") { return .linear }
        if isHost("zoom.us") { return .zoom }
        if host == "meet.google.com" { return .googleMeet }
        return .other
    }

    private static func readableTitle(_ anchor: String?, url: URL, kind: Kind) -> String {
        if let anchor, !anchor.isEmpty,
           !anchor.lowercased().hasPrefix("http://"), !anchor.lowercased().hasPrefix("https://"),
           !anchor.lowercased().hasPrefix("www.") {
            return shortened(anchor)
        }
        let components = url.pathComponents.filter { $0 != "/" }
        switch kind {
        case .github:
            if components.count >= 2 { return shortened(components.prefix(2).joined(separator: "/")) }
        case .linear:
            if let issue = components.firstIndex(of: "issue"), components.indices.contains(issue + 1) {
                return shortened(components[issue + 1])
            }
        case .figma:
            if components.count >= 3 { return shortened(components[2].replacingOccurrences(of: "-", with: " ")) }
        default: break
        }
        return shortened(Self(url: url, title: "", kind: kind).kindLabel)
    }

    private static func shortened(_ text: String) -> String {
        text.count > 56 ? String(text.prefix(55)) + "…" : text
    }

    private static func hostName(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension CalendarEvent {
    public var resources: [EventResource] {
        EventResource.extract(description: description, location: location, excluding: joinURL)
    }
}
