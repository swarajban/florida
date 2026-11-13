import SwiftUI

struct DayBlockingControl: View {
    private enum Choice: CaseIterable, Hashable {
        case automatic, blocks, doesNotBlock

        init(_ blocksDay: Bool?) {
            switch blocksDay {
            case nil: self = .automatic
            case true: self = .blocks
            case false: self = .doesNotBlock
            }
        }

        var blocksDay: Bool? {
            switch self {
            case .automatic: nil
            case .blocks: true
            case .doesNotBlock: false
            }
        }

        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .blocks: "Blocks"
            case .doesNotBlock: "Does not block"
            }
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var blocksDay: Bool?
    let identifier: String

    var body: some View {
        Group {
            #if os(iOS)
            if dynamicTypeSize >= .xxxLarge {
                menu
            } else {
                ViewThatFits(in: .horizontal) {
                    segments.fixedSize(horizontal: true, vertical: true)
                    menu
                }
            }
            #else
            segments
            #endif
        }
    }

    private var segments: some View {
        Picker("Blocks my day", selection: Binding(
            get: { Choice(blocksDay) },
            set: { blocksDay = $0.blocksDay })) {
            ForEach(Choice.allCases, id: \.self) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .labelsHidden()
        .accessibilityIdentifier(identifier)
        .accessibilityValue(Choice(blocksDay).title)
    }

    private var menu: some View {
        Menu {
            ForEach(Choice.allCases, id: \.self) { choice in
                Button {
                    blocksDay = choice.blocksDay
                } label: {
                    if choice == Choice(blocksDay) {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
            }
        } label: {
            HStack {
                Text(Choice(blocksDay).title)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
            }
        }
        .accessibilityLabel("Blocks my day")
        .accessibilityIdentifier(identifier)
        .accessibilityValue(Choice(blocksDay).title)
    }
}
