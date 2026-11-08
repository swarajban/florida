import FloridaKit
import SwiftUI

@main
struct FloridaMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
