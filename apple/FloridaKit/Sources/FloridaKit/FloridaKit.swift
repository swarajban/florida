import Foundation

/// FloridaKit holds the models, the local SQLite store, the sync client, and the
/// keyboard engine shared by the macOS app, the iOS app, and the widgets.
public enum Florida {
    /// App group shared by the apps and the widget extension.
    public static let appGroup = "group.com.swarajban.florida"

    /// Sync server used when no other server has been configured.
    public static let defaultServerURL = URL(string: "https://florida.fly.dev")!
}
