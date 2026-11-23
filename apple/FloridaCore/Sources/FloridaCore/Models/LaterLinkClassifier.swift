import Foundation

public enum LaterLinkClassifier {
    public enum Destination: Hashable, Sendable {
        case later(LaterItem.Kind)
        case task
    }

    public static func classify(_ url: URL) -> Destination {
        classify(url.absoluteString)
    }

    public static func classify(_ string: String) -> Destination {
        guard let url = LaterItem.webURL(string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let hostname = url.host?.lowercased() else { return .task }
        let host = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
        let parts = url.path.lowercased().split(separator: "/")
        func isHost(_ domain: String) -> Bool {
            host == domain || host.hasSuffix("." + domain)
        }

        if ["youtube.com", "youtu.be", "vimeo.com"].contains(where: isHost) { return .later(.video) }
        if ["myshopify.com", "shopify.com", "maps.apple.com", "maps.app.goo.gl",
            "maps.google.com", "docs.google.com", "drive.google.com", "notion.so", "notion.site",
            "readthedocs.io", "developer.mozilla.org", "developers.google.com"].contains(where: isHost)
            || (isHost("google.com") && parts.first == "maps")
            || (isHost("github.com") && parts.count >= 2)
            || host.hasPrefix("docs.") || host.hasPrefix("shop.")
            || host.range(of: #"(^|\.)amazon\.(com|ca|de|fr|it|es|in|nl|se|pl|sg|ae|sa|eg|co\.uk|co\.jp|com\.au|com\.br|com\.mx|com\.tr)$"#, options: .regularExpression) != nil {
            return .task
        }
        if ["substack.com", "medium.com", "nytimes.com", "theguardian.com"].contains(where: isHost)
            || host.hasPrefix("blog.") || host.hasPrefix("news.")
            || parts.dropLast().contains(where: { ["blog", "p", "posts"].contains($0) })
            || url.path.range(of: #"/[0-9]{4}/[0-9]{1,2}/"#, options: .regularExpression) != nil {
            return .later(.article)
        }
        if parts.contains(where: { ["dp", "product", "products", "shop", "docs", "documentation"].contains($0) }) {
            return .task
        }
        return .later(.article)
    }
}
