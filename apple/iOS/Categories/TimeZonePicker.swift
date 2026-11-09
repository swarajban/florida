import SwiftUI

/// A searchable list of IANA time zones, the device's own first.
struct TimeZonePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    @State private var query = ""

    var body: some View {
        List {
            if query.isEmpty {
                Section("This device") {
                    row(TimeZone.autoupdatingCurrent.identifier)
                }
            }
            Section {
                ForEach(matches, id: \.self) { identifier in
                    row(identifier)
                }
            }
        }
        .searchable(text: $query, prompt: "City or region")
        .navigationTitle("Time Zone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var matches: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        guard !query.isEmpty else { return all }
        let needle = query.replacingOccurrences(of: " ", with: "_")
        return all.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    private func row(_ identifier: String) -> some View {
        Button {
            selection = identifier
            dismiss()
        } label: {
            HStack {
                Text(identifier.replacingOccurrences(of: "_", with: " "))
                    .foregroundStyle(.primary)
                Spacer()
                if identifier == selection {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .accessibilityAddTraits(identifier == selection ? .isSelected : [])
    }
}
