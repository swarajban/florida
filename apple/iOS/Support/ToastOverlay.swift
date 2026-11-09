import FloridaKit
import SwiftUI

/// The model's current `Toast` as a banner above the tab bar, with Undo when it has one. Each tab
/// attaches it with `.toastOverlay()` so it sits inside that tab's safe area.
struct ToastOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let toast = model.toast {
                HStack(spacing: 10) {
                    Image(systemName: toast.systemImage)
                        .foregroundStyle(tint(toast.style))
                        .accessibilityHidden(true)
                    Text(toast.message)
                        .font(.subheadline)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if !toast.undo.isEmpty {
                        Button("Undo") {
                            model.undo(toast)
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    Button {
                        model.dismissToast()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Dismiss")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .accessibilityElement(children: .contain)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.snappy(duration: 0.25), value: model.toast?.id)
        .onChange(of: model.toast?.id) { _, _ in
            if let toast = model.toast {
                AccessibilityNotification.Announcement(toast.message).post()
            }
        }
    }

    private func tint(_ style: Toast.Style) -> Color {
        switch style {
        case .info: .secondary
        case .success: .green
        case .error: .red
        }
    }
}

extension View {
    /// Shows the app's toast at the bottom of this view.
    func toastOverlay() -> some View {
        overlay(alignment: .bottom) {
            ToastOverlay()
        }
    }
}
