import FloridaKit

// Jump mode: `f` puts a short label on every task and event on screen, in the calendar and in the
// task pane, and typing a label opens its item: a task in its editor, an event in its detail
// popover. Both show the key of each of their controls, so `f`, a label and one more key finishes
// a task, moves its due date, joins a call or answers an invitation. The labels are FloridaCore's
// `JumpLabels`; the views draw `jumpLabel(for:)`, so a two-key label shrinks to its second key
// once the first is typed.
//
// "On screen" is taken when `f` is pressed: what the time grid and the task pane are scrolled past
// gets no label, which keeps the single keys for what can be seen. A scroll that a key started
// and that is still running counts as finished, so `G` then `f` labels where `G` lands. The
// labels do not follow later scrolling; Esc and `f` again labels the new view.

extension AppModel {
    /// What is left to type to select `item`: nil outside jump mode, and for an item the keys
    /// typed so far have ruled out.
    func jumpLabel(for item: ItemID) -> String? {
        jump?.remaining[item]
    }

    /// `f`: labels the calendar's items in `j` / `k` order, then the task pane's, so the calendar
    /// gets the home row. A task shown in both keeps one label, and so does one on screen in only
    /// one of them. Free gaps get none: they are neither tasks nor events, and would use up the
    /// single keys.
    func startJump() {
        let viewport = gridViewport
        let paneItems = isTasksPaneVisible ? orderedTaskItems.filter(paneItemsOnScreen.contains) : []
        let labels = JumpLabels(items: calendarItems(onScreenIn: viewport) + paneItems)
        guard !labels.isEmpty else {
            statusMessage = "Nothing on screen to jump to"
            return
        }
        // The labels are about to move the selection off the event this popover shows.
        eventDetailID = nil
        jumpGridViewport = viewport
        jump = labels
        statusMessage = "Type a label to open · Esc cancels"
    }

    /// The stretch of the time grid on screen, or the stretch an animated scroll is on its way
    /// to. Nil in the month view, which does not scroll, and until the grid has reported where
    /// it is.
    private var gridViewport: JumpViewport? {
        guard viewMode != .month, !gridVisibleRect.isEmpty else { return nil }
        let top = gridScrollTarget ?? gridVisibleRect.minY
        return JumpViewport(top: top, bottom: top + gridVisibleRect.height)
    }

    /// The calendar's items in `j` / `k` order, less the free gaps and the blocks scrolled out of
    /// `viewport`. All-day bars sit above the scrolling grid, so they always count; a task with
    /// several blocks counts when one of them can hold a label.
    private func calendarItems(onScreenIn viewport: JumpViewport?) -> [ItemID] {
        let items = gridLayout.orderedItems.filter { !$0.isGap }
        guard let viewport else { return items }
        var onScreen = Set(gridLayout.allDayBlocks.map(\.item))
        for block in gridLayout.blocksByDay.joined() {
            let rows = GridGeometry.rows(
                startMinute: block.startMinute, endMinute: block.endMinute, grid: CalendarGridView.grid)
            if JumpBadge.top(onBlockFrom: rows.lowerBound, to: rows.upperBound, in: viewport) != nil {
                onScreen.insert(block.item)
            }
        }
        return items.filter(onScreen.contains)
    }

    /// Leaves jump mode and takes its hint off the status bar.
    func endJump() {
        guard jump != nil else { return }
        jump = nil
        statusMessage = nil
    }

    /// One key while the labels are up; returns true when jump mode consumed it. A label's last
    /// key opens its item and leaves the mode; the first key of a two-key label narrows the
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

    /// Selects a labelled item in the focused pane when it is shown there, else in the other one,
    /// and opens it. Typing a label and clicking one both end here. The gym and project time are
    /// only selected: Return on them leaves the calendar for Settings or the projects, which a
    /// label should not do.
    func selectJumped(_ item: ItemID) {
        let onCalendar = gridLayout.day(of: item) != nil
        let inPane = isTasksPaneVisible && orderedTaskItems.contains(item)
        guard onCalendar || inPane else {
            // A sync or a finished task took it off screen while the labels were up.
            statusMessage = "That item is no longer on screen"
            return
        }
        let staysInPane = inPane && (focus == .tasks || !onCalendar)
        select(item, in: staysInPane ? .tasks : .calendar)
        if selectedTask != nil || selectedEvent != nil {
            editSelection()
        }
    }
}
