import AppKit
import FloridaKit
import SwiftUI

// The task editor's keys. A sheet is a window of its own, and the main window's key monitor
// leaves sheets alone, so the editor has this one. Which control a key reaches is FloridaCore's
// `TaskEditorKey`; this file finds out what has the keyboard and moves it.

/// The editor's hold on its window's keyboard focus. The sheet keeps one and asks it to put the
/// keyboard in a date field or to take it out of every field.
@MainActor
final class TaskEditorKeyboard {
    fileprivate(set) weak var window: NSWindow?
    fileprivate var hasInitializedFocus = false

    /// Takes the keyboard out of every field, so the next key acts.
    func dropFocus() {
        window?.makeFirstResponder(nil)
    }

    /// What has the keyboard in `window`, as `TaskEditorKey` sorts it.
    static func focus(in window: NSWindow) -> TaskEditorKey.Focus {
        guard let responder = window.firstResponder, responder !== window else { return .none }
        if responder is NSText { return .text }
        var view = responder as? NSView
        while let current = view {
            if current is NSDatePicker { return .date }
            view = current.superview
        }
        return .control
    }

}

/// An invisible view that watches the editor sheet's key presses. A press that `TaskEditorKey`
/// gives to a control goes to `onPress`; Escape in a field takes the keyboard out of the field
/// (a second Escape cancels the sheet); everything else goes on to the fields and buttons.
///
/// With `startsUnfocused` the sheet opens with the keyboard in no field, so the keys act at once:
/// AppKit puts the keyboard in a sheet's first text field as it opens, and this takes it out
/// again until the user has pressed or clicked something.
struct TaskEditorKeyMonitor: NSViewRepresentable {
    let keyboard: TaskEditorKeyboard
    let startsUnfocused: Bool
    let onPress: (TaskEditorKey.Press) -> Void
    var onPriority: ((Priority) -> Void)?

    func makeNSView(context: Context) -> TaskEditorKeyHostView {
        let view = TaskEditorKeyHostView()
        view.keyboard = keyboard
        view.startsUnfocused = startsUnfocused
        view.onPress = onPress
        view.onPriority = onPriority
        return view
    }

    func updateNSView(_ view: TaskEditorKeyHostView, context: Context) {
        view.onPress = onPress
        view.onPriority = onPriority
    }
}

final class TaskEditorKeyHostView: NSView {
    var keyboard: TaskEditorKeyboard?
    var startsUnfocused = false
    var onPress: ((TaskEditorKey.Press) -> Void)?
    var onPriority: ((Priority) -> Void)?
    private var monitor: Any?
    private var focusObservation: NSKeyValueObservation?
    private let box = HostBox()
    /// The user has not pressed or clicked anything yet, so a text field that takes the keyboard
    /// did it unasked.
    private var isUntouched = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        keyboard?.window = window
        guard let window else { return }
        box.view = self
        let box = box
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            let handled = MainActor.assumeIsolated { box.view?.handle(event) ?? false }
            return handled ? nil : event
        }
        guard let keyboard, startsUnfocused, !keyboard.hasInitializedFocus else { return }
        keyboard.hasInitializedFocus = true
        isUntouched = true
        focusObservation = window.observe(\.firstResponder) { _, _ in
            // AppKit changes the first responder on the main thread.
            MainActor.assumeIsolated { box.view?.dropUnaskedFocus() }
        }
        dropUnaskedFocus()
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        focusObservation = nil
    }

    /// Takes the keyboard back out of a text field that took it as the sheet opened. Not in the
    /// middle of AppKit's own change of first responder, so on the next turn of the run loop.
    private func dropUnaskedFocus() {
        guard isUntouched, window?.firstResponder is NSText else { return }
        Task { @MainActor [weak self] in
            guard let self, isUntouched, let window, window.firstResponder is NSText else { return }
            window.makeFirstResponder(nil)
        }
    }

    func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        isUntouched = false
        guard !SelectorInput.isEditing(in: window) else { return false }
        guard event.type == .keyDown, let chord = KeyChord(event: event) else {
            // A click, or a key that is no chord: the user has taken over.
            isUntouched = false
            return false
        }
        let focus = TaskEditorKeyboard.focus(in: window)
        if event.isARepeat, chord == KeyChord("space"), focus != .text { return true }
        if chord.modifiers == [.command], let number = Int(chord.key), (1...4).contains(number) {
            let priorities: [Priority] = [.asap, .high, .medium, .low]
            isUntouched = false
            onPriority?(priorities[number - 1])
            return onPriority != nil
        }
        if chord == KeyChord("escape") {
            guard focus == .text || focus == .date else { return false }
            // Escape first belongs to text that is still being composed.
            if let text = window.firstResponder as? NSTextView, text.hasMarkedText() { return false }
            window.makeFirstResponder(nil)
            return true
        }
        if let press = TaskEditorKey.press(for: chord, focus: focus) {
            isUntouched = false
            onPress?(press)
            return true
        }
        if chord == KeyChord("tab") || chord == KeyChord("tab", [.shift]) {
            isUntouched = false
            return false
        }
        // With the keyboard in no field a stray letter has nowhere to go; swallowed, it does not beep.
        let isPlain = chord.modifiers.subtracting([.shift]).isEmpty && (chord.key.count == 1 || chord.key == "space")
        return focus == .none && isPlain
    }
}

/// A weak reference the monitor's closures may capture whatever their isolation; it is only
/// read on the main actor.
private final class HostBox: @unchecked Sendable {
    weak var view: TaskEditorKeyHostView?
}
