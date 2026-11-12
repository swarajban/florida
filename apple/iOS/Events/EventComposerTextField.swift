import SwiftUI
import UIKit

struct EventComposerTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var focused: Bool
    var identifier = ""
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> FocusedEventTextField {
        let field = FocusedEventTextField()
        field.delegate = context.coordinator
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.returnKeyType = .done
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: FocusedEventTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholder = placeholder
        field.accessibilityIdentifier = identifier
        if field.text != text { field.text = text }
        field.wantsFocus = focused
        field.updateFocus()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: EventComposerTextField

        init(_ parent: EventComposerTextField) { self.parent = parent }

        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ field: UITextField) { parent.focused = true }
        func textFieldDidEndEditing(_ field: UITextField) { parent.focused = false }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

final class FocusedEventTextField: UITextField {
    var wantsFocus = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateFocus()
    }

    func updateFocus() {
        if wantsFocus, window != nil, !isFirstResponder { becomeFirstResponder() }
        if !wantsFocus, isFirstResponder { resignFirstResponder() }
    }
}
