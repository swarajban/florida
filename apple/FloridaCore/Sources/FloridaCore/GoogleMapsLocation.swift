import Foundation

public struct GoogleMapsLocation: Equatable, Sendable {
    public enum Action {
        case search, directions
    }

    public let name: String

    public init?(_ location: String) {
        let name = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, Self.webLink(name) == nil else { return nil }

        let label = name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !Self.nonPhysicalLabels.contains(label),
              label.range(of: Self.virtualLocationPattern, options: .regularExpression) == nil
        else { return nil }
        self.name = name
    }

    public static func webLink(_ location: String) -> URL? {
        let value = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(where: \.isWhitespace),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    public func url(for action: Action, appInstalled: Bool) -> URL? {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let query = name.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return switch (action, appInstalled) {
        case (.search, true): URL(string: "comgooglemaps://?q=\(query)")
        case (.directions, true): URL(string: "comgooglemaps://?daddr=\(query)&directionsmode=driving")
        case (.search, false): URL(string: "https://www.google.com/maps/search/?api=1&query=\(query)")
        case (.directions, false): URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(query)")
        }
    }

    private static let nonPhysicalLabels: Set<String> = [
        "-", "—", "n/a", "none", "tbd", "to be determined", "remote", "virtual", "online",
        "phone", "phone call", "dial-in", "video call", "video conference", "conference call",
        "zoom", "meet", "google meet", "teams", "ms teams", "microsoft teams", "webex", "skype",
    ]

    private static let virtualLocationPattern =
        #"://|^(tel|mailto|sip|facetime|zoommtg|msteams):|\b(meet\.google\.com|zoom\.(us|com)|teams\.microsoft\.com|webex\.com)\b|^(remote|virtual|online|zoom|google meet|microsoft teams|webex) (meeting|call)$|^(?:\+?[0-9]{1,3} )?\(?[0-9]{2,4}\)?[ .-][0-9]{2,4}[ .-][0-9]{4}$"#
}
