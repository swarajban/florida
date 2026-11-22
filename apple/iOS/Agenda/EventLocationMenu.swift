import FloridaKit
import SwiftUI
import UIKit

struct EventLocationMenu: View {
    @Environment(\.openURL) private var openURL
    #if DEBUG
    @State private var recordedURL: URL?
    #endif

    let location: GoogleMapsLocation
    let eventID: String

    var body: some View {
        Menu {
            Button {
                open(.search)
            } label: {
                Label("Open in Google Maps", systemImage: "map")
            }
            Button {
                open(.directions)
            } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond")
            }
        } label: {
            Label(location.name, systemImage: "mappin.and.ellipse")
                .foregroundStyle(Color.accentColor)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityHint("Shows Google Maps and directions options")
        .accessibilityIdentifier("event-location-\(eventID)")
        #if DEBUG
        .accessibilityValue(recordedURL?.absoluteString ?? "")
        #endif
    }

    private func open(_ action: GoogleMapsLocation.Action) {
        guard let appURL = location.url(for: action, appInstalled: true),
              let webURL = location.url(for: action, appInstalled: false)
        else { return }
        #if DEBUG
        if LaunchOptions.demoData, UserDefaults.standard.bool(forKey: "uiRecordMapOpens") {
            recordedURL = webURL
            return
        }
        #endif
        if UIApplication.shared.canOpenURL(appURL) {
            openURL(appURL) { accepted in
                if !accepted { openURL(webURL) }
            }
        } else {
            openURL(webURL)
        }
    }
}
