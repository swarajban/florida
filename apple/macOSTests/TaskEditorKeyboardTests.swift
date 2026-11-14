import AppKit
import FloridaKit
import Testing

@Suite(.serialized) @MainActor
struct TaskEditorKeyboardTests {
    @Test func reattachingTheMonitorDoesNotTakeTheCaret() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let field = NSTextField(frame: NSRect(x: 20, y: 80, width: 300, height: 24))
        field.stringValue = "alpha bravo charlie"
        let host = TaskEditorKeyHostView()
        let keyboard = TaskEditorKeyboard()
        host.keyboard = keyboard
        host.startsUnfocused = true
        let content = try #require(window.contentView)
        content.addSubview(field)
        content.addSubview(host)
        window.makeKeyAndOrderFront(nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        #expect(!host.handle(click))
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        host.removeFromSuperview()
        content.addSubview(host)
        try await Task.sleep(for: .milliseconds(20))
        #expect(window.firstResponder === editor)
        #expect(editor.selectedRange() == NSRange(location: 6, length: 0))
        host.removeFromSuperview()
        let replacement = TaskEditorKeyHostView()
        replacement.keyboard = keyboard
        replacement.startsUnfocused = true
        content.addSubview(replacement)
        try await Task.sleep(for: .milliseconds(20))
        #expect(window.firstResponder === editor)
        #expect(editor.selectedRange() == NSRange(location: 6, length: 0))
    }

    @Test func spaceIsConsumedOnceAndAutorepeatCannotCompleteAgain() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let host = TaskEditorKeyHostView()
        host.keyboard = TaskEditorKeyboard()
        var presses: [TaskEditorKey.Press] = []
        host.onPress = { presses.append($0) }
        window.contentView?.addSubview(host)
        window.makeFirstResponder(nil)
        do {
            SelectorWindowHost.register(window)
            defer { SelectorWindowHost.unregister(window) }
            #expect(!host.handle(try event(" ", code: 49, in: window)))
            #expect(!host.handle(try event(" ", code: 49, in: window, repeats: true)))
            #expect(!host.handle(try event("\u{1b}", code: 53, in: window)))
            #expect(presses.isEmpty)
        }
        #expect(host.handle(try event(" ", code: 49, in: window)))
        #expect(presses == [.init(key: .markDone)])
        #expect(host.handle(try event(" ", code: 49, in: window, repeats: true)))
        #expect(presses == [.init(key: .markDone)])

        let field = NSTextField(frame: NSRect(x: 20, y: 80, width: 300, height: 24))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = window.firstResponder
        for (text, code): (String, UInt16) in [("c", 8), ("t", 17), ("s", 1), (" ", 49), ("\u{f702}", 123)] {
            #expect(!host.handle(try event(text, code: code, in: window)))
            #expect(window.firstResponder === editor)
        }
        #expect(!host.handle(try event(" ", code: 49, in: window, repeats: true)))
        #expect(presses == [.init(key: .markDone)])
    }

    @Test func handledShortcutStaysSuppressedAcrossWindowsButFreshTypingDoesNot() throws {
        _ = NSApplication.shared
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer {
            first.orderOut(nil)
            second.orderOut(nil)
        }
        let state = ShortcutRepeatState()
        let origin = TaskEditorKeyHostView()
        origin.shortcutRepeats = state
        let destination = TaskEditorKeyHostView()
        destination.shortcutRepeats = state
        first.contentView?.addSubview(origin)
        second.contentView?.addSubview(destination)
        let field = NSTextField(frame: NSRect(x: 20, y: 80, width: 300, height: 24))
        field.stringValue = "Original title"
        second.contentView?.addSubview(field)
        origin.onPress = { _ in second.makeFirstResponder(field) }
        #expect(first.makeFirstResponder(nil))
        #expect(origin.handle(try event("t", code: 17, in: first)))
        #expect(second.firstResponder is NSTextView)
        #expect(destination.handle(try event("t", code: 17, in: second, repeats: true)))
        #expect(field.stringValue == "Original title")
        let release = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
            timestamp: 2, windowNumber: second.windowNumber, context: nil, characters: "t",
            charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        #expect(!destination.handle(release))
        #expect(!destination.handle(try event("t", code: 17, in: second)))
        #expect(!destination.handle(try event("t", code: 17, in: second, repeats: true)))
    }

    @Test func selectorOriginRevealsAnOffscreenControlWithoutTakingFocus() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 900))
        let origin = SelectorOrigin()
        let control = SelectorOriginHost(frame: NSRect(x: 20, y: 700, width: 100, height: 24))
        control.origin = origin
        document.addSubview(control)
        scroll.documentView = document
        let field = NSTextField(frame: NSRect(x: 20, y: 208, width: 260, height: 24))
        field.stringValue = "alpha bravo charlie"
        let content = try #require(window.contentView)
        content.addSubview(scroll)
        content.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(origin.view === control)
        #expect(!control.visibleRect.contains(control.bounds))
        origin.reveal()
        #expect(control.visibleRect.contains(control.bounds))
        #expect(scroll.contentView.bounds.minY > 0)
        #expect(window.firstResponder === editor)
        #expect(editor.selectedRange() == NSRange(location: 6, length: 0))
    }

    @Test func dismissingASelectorPreservesNewTextFocus() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let field = NSTextField(frame: NSRect(x: 20, y: 80, width: 300, height: 24))
        field.stringValue = "alpha bravo charlie"
        try #require(window.contentView).addSubview(field)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        var dismissed = false
        await SelectorOrigin.finishDismissal(in: window, preservingFocusAt: NSPoint(x: 30, y: 92)) { dismissed = true }
        #expect(!dismissed)
        #expect(window.firstResponder === editor)
        #expect(editor.selectedRange() == NSRange(location: 6, length: 0))
        window.makeFirstResponder(nil)
        await SelectorOrigin.finishDismissal(in: window, preservingFocusAt: nil) { dismissed = true }
        #expect(dismissed)
    }

    @Test func dismissingASelectorClearsAutomaticallyRestoredTextFocus() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let field = NSTextField(frame: NSRect(x: 20, y: 80, width: 300, height: 24))
        try #require(window.contentView).addSubview(field)
        window.makeKeyAndOrderFront(nil)
        for point in [NSPoint?.none, NSPoint(x: 350, y: 20)] {
            #expect(window.makeFirstResponder(field))
            #expect(window.firstResponder is NSTextView)
            let editor = try #require(field.currentEditor() as? NSTextView)
            if let point {
                #expect(!field.bounds.contains(field.convert(point, from: nil)))
            }
            var dismissed = false
            await SelectorOrigin.finishDismissal(in: window, preservingFocusAt: point) { dismissed = true }
            #expect(dismissed, "point=\(String(describing: point)), field=\(field.frame), delegate=\(String(describing: editor.delegate))")
            #expect(!(window.firstResponder is NSTextView))
        }
    }

    private func event(_ characters: String, code: UInt16, in window: NSWindow, repeats: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: repeats, keyCode: code))
    }
}
