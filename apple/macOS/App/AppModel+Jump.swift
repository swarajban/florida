import FloridaKit

// Jump mode: `f` puts a short label on every task and event on screen, in the calendar and in the
// task pane, and typing a label selects its item. The usual keys then act on it: Space, `e`, `s`
// or `p` on a task; ⇧E, `r y`, `v` or `o` on an event. The labels are FloridaCore's `JumpLabels`;
// the views draw `jumpLabel(for:)`, so a two-key label shrinks to its second key once the first
// is typed.

extension AppModel {
    /// What is left to type to select `item`: nil outside jump mode, and for an item the keys
    /// typed so far have ruled out.
    func jumpLabel(for item: ItemID) -> String? {
        jump?.remaining[item]
    }

    /// `f`: labels the calendar's items in `j` / `k` order, then the task pane's, so the calendar
    /// gets the home row. A task shown in both keeps one label. Free gaps get none: they are
    /// neither tasks nor events, and would use up the single keys.
    func startJump() {
        let calendarItems = gridLayout.orderedItems.filter { !$0.isGap }
        let paneItems = isTasksPaneVisible ? orderedTaskItems : []
        let labels = JumpLabels(items: calendarItems + paneItems)
        guard !labels.isEmpty else {
            statusMessage = "Nothing on screen to jump to"
            return
        }
        // The labels are about to move the selection off the event this popover shows.
        eventDetailID = nil
        jump = labels
        statusMessage = "Type a label to select · Esc cancels"
    }

    /// Leaves jump mode and takes its hint off the status bar.
    func endJump() {
        guard jump != nil else { return }
        jump = nil
        statusMessage = nil
    }

    /// One key while the labels are up; returns true when jump mode consumed it. A label's last
    /// key selects its item and leaves the mode; the first key of a two-key label narrows the
    /// labels. Anything else leaves the mode without running: a mistyped label must not delete
    /// or complete whatever was selected before. ⌘ shortcuts leave the mode and still run.
    func handleJumpKey(_ chord: KeyChord) -> Bool {
        guard var labels = jump else { return false }
        if chord.modifiers.contains(.command) {
            endJump()
            return false
        }
        guard chord.key.count == 1, chord.modifiers.subtracting([.shift]).isEmpty else {
            endJump()
            return true
        }
        switch labels.type(chord.key) {
        case .selected(let item):
            endJump()
            selectJumped(item)
        case .pending:
            jump = labels
        case .unmatched:
            endJump()
        }
        return true
    }

    /// Selects a labelled item in the focused pane when it is shown there, else in the other one.
    private func selectJumped(_ item: ItemID) {
        let onCalendar = gridLayout.day(of: item) != nil
        let inPane = isTasksPaneVisible && orderedTaskItems.contains(item)
        guard onCalendar || inPane else {
            // A sync or a finished task took it off screen while the labels were up.
            statusMessage = "That item is no longer on screen"
            return
        }
        let staysInPane = inPane && (focus == .tasks || !onCalendar)
        select(item, in: staysInPane ? .tasks : .calendar)
    }
}
