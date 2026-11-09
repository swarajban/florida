import SwiftUI

// Since iOS 26 a confirmation dialog is a popover anchored to the view its modifier sits on, so a
// dialog attached to a whole List opens at the list's edge, far from the row that asked for it.
// These helpers let one `@State var deleting: Item?` drive a dialog on each row instead.

extension Binding {
    /// `self` as one row sees it: holds `item` only while the binding does, and clears the binding
    /// when set to nil. `key` says which field identifies an item.
    func only<Item, Key: Equatable>(_ item: Item, by key: @escaping (Item) -> Key) -> Binding<Item?> where Value == Item? {
        Binding<Item?>(
            get: { wrappedValue.map(key) == key(item) ? wrappedValue : nil },
            set: { newValue in
                if newValue == nil, wrappedValue.map(key) == key(item) {
                    wrappedValue = nil
                }
            })
    }

    func only<Item: Identifiable>(_ item: Item) -> Binding<Item?> where Value == Item? {
        only(item, by: \.id)
    }

    /// True while the optional holds a value; setting it to false clears the value.
    func isPresent<Item>() -> Binding<Bool> where Value == Item? {
        Binding<Bool>(
            get: { wrappedValue != nil },
            set: { if !$0 { wrappedValue = nil } })
    }
}
