import FloridaKit
import SwiftUI
import WidgetKit

/// One switch per `JoySetting`, stored in the App Group defaults the widgets read too.
struct JoySettingsSection: View {
    var body: some View {
        Section {
            ForEach(JoySetting.allCases) { setting in
                JoyToggle(setting: setting)
            }
        } header: {
            Text("Delight")
        } footer: {
            Text("All of these run on the device and never wait on the server.")
        }
    }
}

private struct JoyToggle: View {
    let setting: JoySetting
    @AppStorage private var isOn: Bool

    init(setting: JoySetting) {
        self.setting = setting
        _isOn = AppStorage(wrappedValue: true, setting.rawValue, store: .florida)
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(setting.title)
                Text(setting.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: isOn) { _, _ in
            if setting == .joinCountdownWidget {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}
