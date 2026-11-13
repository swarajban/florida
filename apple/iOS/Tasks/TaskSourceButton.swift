import FloridaKit
import SwiftUI

struct TaskSourceButton: View {
    @Environment(\.openURL) private var openURL
    let source: TaskSource
    var identifier = "task-source-open"
    var compact = false

    var body: some View {
        if let url = source.openURL {
            Button {
                openURL(url)
            } label: {
                if compact {
                    Image(systemName: source.symbolName)
                        .font(.subheadline)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                } else {
                    Label("Open source", systemImage: source.symbolName)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Open source: \(source.title)")
            .accessibilityHint("Opens the task's source without editing the task")
            .accessibilityIdentifier(identifier)
        }
    }
}

struct SourceOpenTestHarness: ViewModifier {
    @State private var openedURL: String?

    func body(content: Content) -> some View {
        #if DEBUG
        if LaunchOptions.recordSourceOpens {
            content
                .environment(\.openURL, OpenURLAction { url in
                    openedURL = url.absoluteString
                    return .handled
                })
                .overlay(alignment: .top) {
                    if let openedURL {
                        Text(openedURL)
                            .font(.caption)
                            .padding(8)
                            .background(.background)
                            .accessibilityIdentifier("source-opened-url")
                            .allowsHitTesting(false)
                    }
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
