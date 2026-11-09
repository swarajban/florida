import SwiftUI

/// Settings › Feel: a switch per small touch. All local; nothing here touches the network.
struct FeelSettingsView: View {
    var body: some View {
        Form {
            Section {
                ForEach(JoyPreference.allCases) { preference in
                    JoyToggle(preference: preference)
                }
            } footer: {
                Text("Everything here is drawn from local data; there are no notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// One preference, stored under its `UserDefaults` key; the grid rebuilds when it changes.
struct JoyToggle: View {
    @Environment(AppModel.self) private var model
    let preference: JoyPreference
    @AppStorage private var isOn: Bool

    init(preference: JoyPreference) {
        self.preference = preference
        _isOn = AppStorage(wrappedValue: true, preference.key)
    }

    var body: some View {
        Toggle(preference.label, isOn: $isOn)
            .onChange(of: isOn) {
                model.rebuildLayout()
            }
    }
}
