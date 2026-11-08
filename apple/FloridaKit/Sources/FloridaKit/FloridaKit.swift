import Foundation
@_exported import FloridaCore

/// FloridaKit holds the local SQLite store, the sync client, and settings shared by the macOS
/// app, the iOS app, and the widgets. Models and pure logic live in FloridaCore, re-exported here.
public enum Florida {
    /// App group shared by the apps and the widget extension.
    public static let appGroup = "group.com.swarajban.florida"

    /// Sync server used when no other server has been configured.
    public static let defaultServerURL = URL(string: "https://florida.fly.dev")!
}
