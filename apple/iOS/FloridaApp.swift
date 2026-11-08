import FloridaKit
import SwiftUI

@main
struct FloridaApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Florida")
                .font(.largeTitle)
            Text(Florida.defaultServerURL.absoluteString)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
