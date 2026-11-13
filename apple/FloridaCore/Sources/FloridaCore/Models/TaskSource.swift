import Foundation

public enum TaskSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case email, slack, github, linear, web
}

public struct TaskSource: Codable, Hashable, Sendable {
    public var url: String
    public var title: String
    public var kind: TaskSourceKind

    public init(url: String, title: String, kind: TaskSourceKind) {
        self.url = url
        self.title = title
        self.kind = kind
    }

    public var openURL: URL? { Self.safeURL(url) }

    public var symbolName: String {
        switch kind {
        case .email: "envelope"
        case .slack: "bubble.left.and.bubble.right"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .linear: "number.square"
        case .web: "link"
        }
    }

    public static func from(url: String, title: String? = nil) -> TaskSource? {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let supplied = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (supplied?.utf16.count ?? 0) <= 200, let parsed = safeURL(text) else { return nil }
        let hostname = parsed.host?.lowercased() ?? ""
        let host = hostname.contains(":") && !hostname.hasPrefix("[") ? "[\(hostname)]" : hostname
        let path = URLComponents(url: parsed, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? parsed.path
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        let kind: TaskSourceKind
        if parsed.scheme?.lowercased() == "mailto" || host == "mail.google.com"
            || ["outlook.office.com", "outlook.office365.com", "outlook.live.com"].contains(host) {
            kind = .email
        } else if host == "slack.com" || host.hasSuffix(".slack.com") {
            kind = .slack
        } else if host == "github.com" || host == "www.github.com" {
            kind = .github
        } else if host == "linear.app" || host.hasSuffix(".linear.app") {
            kind = .linear
        } else {
            kind = .web
        }

        let derived: String
        if parsed.scheme?.lowercased() == "mailto" {
            derived = path.removingPercentEncoding ?? path
        } else if kind == .github, parts.count >= 4,
                  !parts[0].isEmpty, !parts[1].isEmpty,
                  ["pull", "issues"].contains(parts[2]), !parts[3].isEmpty,
                  parts[3].allSatisfy({ $0.isASCII && $0.isNumber }) {
            let label = parts[2] == "pull" ? "PR" : "Issue"
            derived = "\(label) #\(parts[3]) in \(parts[0])/\(parts[1])"
        } else if kind == .linear, let index = parts.firstIndex(of: "issue"), index + 1 < parts.count,
                  parts[index + 1].range(of: #"^[A-Za-z][A-Za-z0-9]*-[0-9]+$"#, options: .regularExpression) != nil {
            derived = "Linear \(parts[index + 1].uppercased())"
        } else {
            derived = host + (path == "/" ? "" : path)
        }
        var shortTitle = derived
        if derived.utf16.count > 120 {
            shortTitle = String(derived.prefix(119))
            while shortTitle.utf16.count > 119 { shortTitle.removeLast() }
            shortTitle += "…"
        }
        return TaskSource(url: text, title: supplied.flatMap { $0.isEmpty ? nil : $0 } ?? shortTitle, kind: kind)
    }

    private static func safeURL(_ text: String) -> URL? {
        guard !text.isEmpty, text.utf16.count <= 4096, !text.contains("\\"),
              text.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let decoded = text.removingPercentEncoding,
              decoded.rangeOfCharacter(from: .controlCharacters) == nil,
              let url = URL(string: text),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), components.user == nil, components.password == nil
        else { return nil }
        switch scheme {
        case "http", "https":
            guard let host = components.host, !host.isEmpty,
                  host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
                  !host.contains("%"), components.port.map({ (0...65535).contains($0) }) ?? true
            else { return nil }
        case "mailto":
            let address = components.path
            guard components.host == nil,
                  address.range(of: #"^[^\s/?#@]+@[^\s/?#@]+$"#, options: .regularExpression) != nil
            else { return nil }
        default:
            return nil
        }
        return url
    }
}
