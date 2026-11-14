#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description='Run portable regressions against actual Mac write/undo methods.')
parser.add_argument('--ref', help='Read app sources from this git ref instead of the working tree.')
args = parser.parse_args()


def source(path):
    if args.ref:
        return subprocess.check_output(['git', 'show', f'{args.ref}:{path}'], cwd=ROOT, text=True)
    return (ROOT / path).read_text()


def method(text, name):
    start = text.index(f'func {name}(')
    start = text.rfind('\n', 0, start) + 1
    end = text.index('\n    }', start) + len('\n    }')
    return text[start:end]


def computed(text, name):
    start = text.index(f'    private var {name}:')
    return text[start:text.index('\n    }', start) + len('\n    }')]


def event_editor(path, name):
    text = source(path)
    start = text.index('        var event = draft', text.index('    private func save()'))
    preparation = text[start:text.index('        guard model.save(event:', start)]
    return ('struct ' + name + ' {\n    var draft: CalendarEvent\n    var original: CalendarEvent\n'
            + '    var isNew = false\n    func prepared() -> CalendarEvent {\n'
            + preparation + '        return event\n    }\n' + method(text, 'cleaned') + '\n}\n')


undo = source('apple/macOS/App/AppModel+Undo.swift')
writes = source('apple/macOS/App/AppModel+Writes.swift')
selection = source('apple/macOS/App/AppModel+Selection.swift')
types = undo[undo.index('struct UndoEntry'):undo.index('/// A short-lived label')]
methods = '\n'.join(method(undo, name) for name in ['recordingUndo', 'pushUndo', 'undo'])
methods += '\n' + '\n'.join(method(writes, name) for name in ['save', 'pinSelection', 'snoozeSelection', 'setPriority', 'deleteTask', 'complete'])
methods += '\n' + method(source('apple/macOS/App/AppModel+Events.swift'), 'save')
methods += '\n' + method(source('apple/macOS/App/AppModel+Events.swift'), 'move')
methods += '\n' + method(source('apple/macOS/App/AppModel+Events.swift'), 'moveSeries')
methods += '\n' + method(source('apple/macOS/App/AppModel+Plan.swift'), 'save')
methods += '\n' + method(source('apple/macOS/App/AppModel+Plan.swift'), 'trimmedOrNil')
methods += '\n' + '\n'.join(method(source('apple/macOS/App/AppModel+Events.swift'), name)
                             for name in ['setBlocksDay', 'delete', 'storedVersion'])
methods += '\n' + method(source('apple/macOS/App/AppModel+Plan.swift'), 'delete')
methods += '\n' + '\n'.join(method(source('apple/macOS/App/AppModel+Categories.swift'), name)
                             for name in ['save', 'deleteCategory'])
if 'var liveSelectedTask:' in selection:
    start = selection.index('    var liveSelectedTask:')
    methods += '\n' + selection[start:selection.index('\n    }', start) + len('\n    }')]

editor = source('apple/macOS/Tasks/TaskEditorSheet.swift')
prepared = computed(editor, 'preparedTask')
recurrence = source('apple/Design/TaskRecurrenceSection.swift')
anchor_update = method(recurrence.replace('private func ', 'func '), 'updateAnchor') if 'func updateAnchor(' in recurrence else ''
editor_harness = r'''
struct TaskEditorSheet {
    var draft: TaskItem
    var original: TaskItem
    var isNew = false
    var sourceURL = ""
    var sourceTitle = ""
    var model = AppModel()
    var somedayIntent: Bool?
    var dateEdits: Set<TaskDateField> = []
    var dueTimeChoice: Bool?
    var startTimeChoice: Bool?
    enum Focus { case title }
    var focus: Focus?
    var hasDue = true
    var dueAt: Date
    var hasStart = false
    var startAt: Date
    var hasPinnedStart = false
    var pinnedStart: Date
    func saved() -> TaskItem { preparedTask }
    mutating func useParsed(_ parsed: TaskDraft) { apply(parsed) }
'''+ computed(editor, 'editedSource') + '\n' + prepared + '\n' + method(editor, 'apply').replace('private func apply', 'mutating func apply') + '\n}\n' + r'''
final class TaskRecurrenceSection {
    var recurrence: TaskRecurrence?
    var wasRecurring = false
    var startDateEdited = false
    func changedAnchor(_ date: Date) {
''' + ('        updateAnchor(date)' if anchor_update else '') + '\n    }\n' + anchor_update + '\n}\n'
ios_editor = source('apple/iOS/Tasks/TaskEditorView.swift')
completion_start = ios_editor.index('        var task = preparedTask', ios_editor.index('    private func completeFromEditor()'))
completion_preparation = ios_editor[completion_start:ios_editor.index('        guard model.complete(', completion_start)]
editor_harness += ('struct TaskEditorView {\n    var draft: TaskItem\n    var original: TaskItem\n'
                   + '    var isNew = false\n    var sourceURL = ""\n    var sourceTitle = ""\n'
                   + '    func saved() -> TaskItem { preparedTask }\n'
                   + '    func completed() -> TaskItem {\n' + completion_preparation + '        return task\n    }\n'
                   + computed(ios_editor, 'trimmedTitle') + '\n' + computed(ios_editor, 'validatedSource')
                   + '\n' + computed(ios_editor, 'preparedTask') + '\n}\n')
editor_harness += event_editor('apple/macOS/Events/EventEditorSheet.swift', 'EventEditorSheet')
editor_harness += event_editor('apple/iOS/Events/EventEditorView.swift', 'EventEditorView')

harness = r'''
import FloridaKit
import Foundation

extension Priority { var displayName: String { rawValue } }
final class AppDatabase {
    __EVENT_SERIES_MEMBER__
    struct EventMutation {
        let from: DateInterval
        let to: DateInterval
        var expectedSeries: [EventSeriesMember]? = nil
    }
    struct TaskMutation {
        let before: TaskItem?
        let after: TaskItem
    }
    var tasks: [String: TaskItem] = [:]
    var beforeComplete: (() -> Void)?
    var beforeSave: (() -> Void)?
    var events: [String: CalendarEvent] = [:]
    var projectDraft: Project?
    var eventInterleave: (() -> Void)?
    func task(id: String) throws -> TaskItem? { tasks[id] }
    func saveTask(_ task: TaskItem) throws {
        beforeSave?()
        beforeSave = nil
        tasks[task.id] = task
    }
    @discardableResult
    func saveTask(
        _ task: TaskItem, original: TaskItem?, somedayIntent: Bool? = nil,
        dateEdits: Set<TaskDateField> = [], now: Date = Date()
    ) throws -> TaskMutation {
        beforeSave?()
        beforeSave = nil
        let before = tasks[task.id]
        var after = task
        if let original, let live = before {
            var fields = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(live)) as! [String: Any]
            let old = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(TaskWrite(original))) as! [String: Any]
            let new = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(TaskWrite(task))) as! [String: Any]
            for key in Set(old.keys).union(new.keys) where key != "expectedRecurrenceRevision" {
                let was = try JSONSerialization.data(withJSONObject: [key: old[key] ?? NSNull()], options: .sortedKeys)
                let now = try JSONSerialization.data(withJSONObject: [key: new[key] ?? NSNull()], options: .sortedKeys)
                if was != now {
                    fields[key] = new[key] ?? NSNull()
                }
            }
            after = try JSONCoding.decoder.decode(TaskItem.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        if dateEdits.contains(.due) {
            after.dueAt = task.dueAt
            after.deadlineType = task.deadlineType
        }
        if dateEdits.contains(.start) { after.startAt = task.startAt }
        if dateEdits.contains(.pin) { after.pinnedStart = task.pinnedStart }
        if let somedayIntent { after.someday = somedayIntent }
        tasks[task.id] = after
        return TaskMutation(before: before, after: after)
    }
    func updateTask(id: String, _ update: (inout TaskItem) throws -> Bool) throws {
        guard var task = tasks[id], task.deletedAt == nil else { return }
        if try update(&task) { tasks[id] = task }
    }
    func completeTask(id: String, at: Date = Date()) throws -> TaskMutation? {
        beforeComplete?()
        beforeComplete = nil
        guard var task = tasks[id], task.isOpen else { return nil }
        let before = task
        task.completedAt = at
        task.completedMinutes = task.durationMinutes
        tasks[id] = task
        return TaskMutation(before: before, after: task)
    }
    @discardableResult
    func deleteTask(id: String) throws -> TaskItem? {
        let before = tasks[id]
        tasks[id]?.deletedAt = Date()
        return before
    }
    func restoreTask(_ snapshot: TaskItem) throws -> Bool {
        var restored = snapshot
        restored.deletedAt = nil
        restored.recurrence = nil
        tasks[snapshot.id] = restored
        return snapshot.recurrence != nil
    }
    func event(id: String) throws -> CalendarEvent? {
        let row = events[id]
        eventInterleave?()
        eventInterleave = nil
        return row
    }
    func saveEvent(_ event: CalendarEvent) throws { events[event.id] = event }
    func saveEvent(_ event: CalendarEvent, recurrence: EventRecurrence?) throws {}
    func saveEvent(_ event: CalendarEvent, original: CalendarEvent?, recurrence: EventRecurrence?) throws {
        guard let original, var live = events[event.id] else { events[event.id] = event; return }
        if event.startAt != original.startAt { live.startAt = event.startAt }
        if event.endAt != original.endAt { live.endAt = event.endAt }
        if event.summary != original.summary { live.summary = event.summary }
        if event.location != original.location { live.location = event.location }
        if event.description != original.description { live.description = event.description }
        events[event.id] = live
    }
    func saveProject(_ project: Project) throws { projectDraft = project }
    func saveProject(_ project: Project, original: Project?) throws { projectDraft = project }
    func saveCategory(_ category: TaskCategory) throws {}
    func deleteCategory(id: String) throws {}
    func deleteProject(id: String) throws {}
    func deleteEvent(id: String) throws { events[id] = nil }
    func setEventBlocksDay(id: String, blocksDay: Bool?) throws { events[id]?.blocksDay = blocksDay }
    func moveEvent(id: String, toStart start: Date, series: Bool = false) throws -> EventMutation {
        let event = events[id]!
        let from = DateInterval(start: event.startAt!, end: event.endAt!)
        let end = start.addingTimeInterval(from.duration)
        events[id]?.startAt = start
        events[id]?.endAt = end
        if series { shiftSiblings(of: event, by: start.timeIntervalSince(from.start), duration: from.duration) }
        return EventMutation(from: from, to: DateInterval(start: start, end: end),
            expectedSeries: series ? seriesMembers(of: events[id]!) : nil)
    }
    @discardableResult
    func moveEventSeries(instanceId: String, start: Date, end: Date) throws -> EventMutation {
        guard let event = events[instanceId], let oldStart = event.startAt, let oldEnd = event.endAt else {
            throw NSError(domain: "test-row", code: 404)
        }
        let from = DateInterval(start: oldStart, end: oldEnd)
        events[instanceId]?.startAt = start
        events[instanceId]?.endAt = end
        shiftSiblings(of: event, by: start.timeIntervalSince(from.start), duration: end.timeIntervalSince(start))
        return EventMutation(from: from, to: DateInterval(start: start, end: end),
            expectedSeries: seriesMembers(of: events[instanceId]!))
    }
    func undoEventMove(id: String, expected: DateInterval, restoring: DateInterval, series: Bool = false,
                       expectedSeries: [EventSeriesMember]? = nil) throws -> Bool {
        eventInterleave?()
        eventInterleave = nil
        guard let live = events[id], live.deletedAt == nil,
              live.startAt == expected.start, live.endAt == expected.end else { return false }
        if series {
            let members = seriesMembers(of: live)
            if let expectedSeries {
                guard members.count == expectedSeries.count,
                      zip(members, expectedSeries).allSatisfy({ live, expected in
                          live.id == expected.id && live.calendarId == expected.calendarId
                              && live.recurringEventId == expected.recurringEventId && live.allDay == expected.allDay
                              && live.status == expected.status && live.startAt == expected.startAt && live.endAt == expected.endAt
                      }) else { return false }
            } else if members.count != 1 { return false }
            shiftSiblings(of: live, by: restoring.start.timeIntervalSince(expected.start), duration: restoring.duration)
        }
        events[id]?.startAt = restoring.start
        events[id]?.endAt = restoring.end
        return true
    }
    func seriesMembers(of event: CalendarEvent) -> [EventSeriesMember] {
        events.values.filter {
            $0.id == event.id || (event.recurringEventId != nil && $0.recurringEventId == event.recurringEventId
                && $0.calendarId == event.calendarId && !$0.allDay && $0.deletedAt == nil)
        }.sorted { $0.id < $1.id }.map(EventSeriesMember.init)
    }
    func shiftSiblings(of event: CalendarEvent, by shift: TimeInterval, duration: TimeInterval) {
        for member in seriesMembers(of: event) where member.id != event.id {
            guard let start = member.startAt else { continue }
            events[member.id]?.startAt = start.addingTimeInterval(shift)
            events[member.id]?.endAt = start.addingTimeInterval(shift + duration)
        }
    }
}
enum Item: Equatable { case task(String), event(String) }
enum DateText {
    static func dayAndTime(_ date: Date, calendar: Calendar) -> String { "time" }
    static func time(_ date: Date) -> String { "time" }
}
final class AppModel {
    static let undoLimit = 50
    var database: AppDatabase? = AppDatabase()
    var undoStack: [UndoEntry] = []
    var statusMessage: String?
    var selection: Item?
    var selectedTask: TaskItem?
    var categoriesById: [String: TaskCategory] = [:]
    var projects: [Project] = []
    var editorQuickAddDraft: QuickAddDraft?
    var editorQuickAddCategoryId: String?
    var selectedSuggestion: Int? { nil }
    var placementsByTask: [String: [Placement]] = [:]
    var calendar = Calendar(identifier: .gregorian)
    var taskListCalendar: Calendar { calendar }
    var ghosts: [String] = []
    var completionCount = 0
    var gridDrag: Int?
    func completionFeedback(for task: TaskItem) { completionCount += 1 }
    func scheduleSync() {}
    func requireEditable(_ event: CalendarEvent) -> Bool { true }
    func didRemove(_ event: CalendarEvent, selecting next: Item?) {}
    static func title(of event: CalendarEvent) -> String { event.summary ?? "Event" }
    func take(_ pick: Int) {}
    func neighbor(of item: Item) -> Item? { nil }
    func item(for task: TaskItem) -> Item { .task(task.id) }
    func showGhost(_ text: String, for duration: Duration = .seconds(1)) { ghosts.append(text) }
    static func quoted(_ text: String) -> String { text }
}
'''
series_types = (ROOT / 'apple/FloridaKit/Sources/FloridaKit/Store/AppDatabase+EventMoves.swift').read_text()
series_start = series_types.index('    public struct EventSeriesMember:')
harness = harness.replace('    __EVENT_SERIES_MEMBER__',
                          series_types[series_start:series_types.index('    public struct EventMutation:', series_start)])
tests = r'''
func task() -> TaskItem {
    TaskItem(id: "task", categoryId: "inbox", title: "Original", durationMinutes: 30,
             priority: .medium, deadlineType: .none, createdAt: Date(), updatedAt: Date())
}
var failed = 0
func check(_ condition: Bool, _ name: String) {
    print("\(condition ? "PASS" : "FAIL") \(name)")
    if !condition { failed += 1 }
}
let model = AppModel()
let initial = task()
let closedDuringCompletion = AppModel()
closedDuringCompletion.database!.tasks[initial.id] = initial
closedDuringCompletion.database!.beforeComplete = { closedDuringCompletion.database!.tasks[initial.id] = nil }
let completedMissing = closedDuringCompletion.complete(initial)
check(!completedMissing && closedDuringCompletion.completionCount == 0,
      "Mac completion cancelled before transaction has no success feedback")
for series in [false, true] {
    let undoMove = AppModel()
    let time = Date(timeIntervalSince1970: 1_794_000_000)
    let from = DateInterval(start: time, duration: 3_600)
    let to = DateInterval(start: time.addingTimeInterval(7_200), duration: 3_600)
    let event = CalendarEvent(id: "event", calendarId: "cal", googleId: "google", status: "confirmed",
                              startAt: to.start, endAt: to.end, allDay: false, updatedAt: time)
    undoMove.database!.events[event.id] = event
    undoMove.database!.eventInterleave = { undoMove.database!.events[event.id]?.location = "Remote room" }
    let restore: UndoEntry.Restore = series
        ? .moveEventSeries(eventId: event.id, from: from, to: to)
        : .moveEvent(eventId: event.id, from: from, to: to)
    undoMove.pushUndo(UndoEntry(label: "Move", restores: [restore], at: time))
    undoMove.undo()
    check(undoMove.database!.events[event.id]?.location == "Remote room"
          && undoMove.database!.events[event.id]?.startAt == from.start,
          "event move undo preserves a sync change inside the predicate/write gap (series=\(series))")
    undoMove.database!.events[event.id] = event
    undoMove.database!.eventInterleave = { undoMove.database!.events[event.id] = nil }
    undoMove.pushUndo(UndoEntry(label: "Move", restores: [restore], at: time))
    undoMove.undo()
    check(undoMove.database!.events[event.id] == nil,
          "event move undo never resurrects a concurrently deleted row (series=\(series))")
    undoMove.database!.events[event.id] = event
    let remoteTime = to.start.addingTimeInterval(1_800)
    undoMove.database!.eventInterleave = {
        undoMove.database!.events[event.id]?.startAt = remoteTime
        undoMove.database!.events[event.id]?.endAt = remoteTime.addingTimeInterval(3_600)
    }
    undoMove.pushUndo(UndoEntry(label: "Move", restores: [restore], at: time))
    undoMove.undo()
    check(undoMove.database!.events[event.id]?.startAt == remoteTime,
          "event move undo refuses a concurrent time change (series=\(series))")

    let producer = AppModel()
    var live = event
    live.startAt = time.addingTimeInterval(10_800)
    live.endAt = time.addingTimeInterval(18_000)
    producer.database!.events[event.id] = live
    if series { producer.moveSeries(of: event, toStart: time) }
    else { producer.move(event: event, toStart: time) }
    producer.undo()
    check(producer.database!.events[event.id]?.startAt == live.startAt
          && producer.database!.events[event.id]?.endAt == live.endAt,
          "event move undo uses the transaction's original times (series=\(series))")
}
model.database!.tasks[initial.id] = initial
model.selectedTask = initial
let start = Date(timeIntervalSince1970: 1_800_000_000)
model.placementsByTask[initial.id] = [Placement(id: "p", taskId: initial.id, startAt: start,
    endAt: start.addingTimeInterval(1800), pinned: false, computedAt: start)]
model.pinSelection(true)
model.setPriority(.high)
check(model.database!.tasks[initial.id]?.pinnedStart == start, "rapid priority after pin preserves the pin despite stale observation")
model.undoStack = []
try model.recordingUndo("No edit", taskId: initial.id) { __NO_EDIT_RESULT__ }
check(model.undoStack.isEmpty, "no-op edit does not consume an undo step")
var closed = initial
closed.completedAt = start
model.database!.tasks[initial.id] = closed
model.selectedTask = closed
model.setPriority(.asap)
check(model.database!.tasks[initial.id]?.priority == .medium, "open-only shortcut refuses a completed stamp")
model.database!.tasks[initial.id] = initial
model.selectedTask = initial
model.deleteTask(initial)
model.database!.tasks[initial.id] = nil
model.undo()
check(model.database!.tasks[initial.id]?.title == initial.title, "delete undo restores full snapshot after sync hard-delete")
model.database!.tasks[initial.id] = initial
model.undoStack = []
try model.recordingUndo("Priority", taskId: initial.id) {
    let before = model.database!.tasks[initial.id]!
    model.database!.tasks[initial.id]?.priority = .high
    __PRIORITY_RESULT__
}
model.database!.tasks[initial.id]?.notes = "Remote notes"
model.undo()
check(model.database!.tasks[initial.id]?.notes == "Remote notes" && model.database!.tasks[initial.id]?.priority == .medium,
      "field-scoped undo keeps unrelated remote edits")
try model.recordingUndo("Priority", taskId: initial.id) {
    let before = model.database!.tasks[initial.id]!
    model.database!.tasks[initial.id]?.priority = .high
    __PRIORITY_RESULT__
}
model.database!.tasks[initial.id]?.priority = .low
model.undo()
check(model.database!.tasks[initial.id]?.priority == .low, "undo refuses a field changed since the action")
let interleaved = AppModel()
interleaved.database!.tasks[initial.id] = initial
try interleaved.recordingUndo("Title edit", taskId: initial.id) {
    interleaved.database!.tasks[initial.id]?.notes = "Concurrent remote notes"
    let before = interleaved.database!.tasks[initial.id]!
    interleaved.database!.tasks[initial.id]?.title = "User title"
    __INTERLEAVED_RESULT__
}
interleaved.undo()
check(interleaved.database!.tasks[initial.id]?.title == initial.title
      && interleaved.database!.tasks[initial.id]?.notes == "Concurrent remote notes",
      "undo transaction snapshot preserves a concurrent update before the user write")
let eventModel = AppModel()
eventModel.database!.tasks[initial.id] = initial
eventModel.selectedTask = initial
eventModel.setPriority(.high)
let event = CalendarEvent(id: "event", calendarId: "calendar", googleId: "google", status: "confirmed", allDay: false, updatedAt: Date())
_ = eventModel.save(event: event)
eventModel.undo()
check(eventModel.database!.tasks[initial.id]?.priority == .high, "undo after event edit never reverts an unrelated task")
let projectModel = AppModel()
projectModel.database!.tasks[initial.id] = initial
projectModel.selectedTask = initial
projectModel.setPriority(.high)
let project = Project(id: "project", name: "A project", createdAt: Date(), updatedAt: Date())
_ = projectModel.save(project: project)
projectModel.undo()
check(projectModel.database!.tasks[initial.id]?.priority == .high, "undo after project edit never reverts an unrelated task")
let category = TaskCategory(id: "category", name: "Category", scheduleId: "schedule", createdAt: Date(), updatedAt: Date())
let omittedActions: [(String, (AppModel) -> Void)] = [
    ("category save", { _ = $0.save(category) }),
    ("category delete", { $0.deleteCategory(category) }),
    ("event blocksDay", { model in
        var allDay = event
        allDay.allDay = true
        model.database!.events[event.id] = allDay
        model.setBlocksDay(allDay, blocksDay: true)
    }),
    ("event delete", { $0.delete(event: event) }),
    ("project delete", { $0.delete(project: project) }),
]
for (name, action) in omittedActions {
    let model = AppModel()
    model.database!.tasks[initial.id] = initial
    model.selectedTask = initial
    model.setPriority(.high)
    action(model)
    model.undo()
    check(model.database!.tasks[initial.id]?.priority == .high, "undo after \(name) never reverts an unrelated task")
}
for changedSibling in [false, true] {
    let producer = AppModel()
    var anchor = event
    anchor.startAt = start
    anchor.endAt = start.addingTimeInterval(3_600)
    anchor.recurringEventId = "series"
    var sibling = anchor
    sibling.id = "sibling"
    sibling.startAt = start.addingTimeInterval(86_400)
    sibling.endAt = start.addingTimeInterval(90_000)
    producer.database!.events[anchor.id] = anchor
    producer.database!.events[sibling.id] = sibling
    producer.moveSeries(of: anchor, toStart: start.addingTimeInterval(3_600))
    if changedSibling {
        producer.database!.events[sibling.id]?.recurringEventId = "other-series"
    }
    producer.undo()
    if changedSibling {
        check(producer.database!.events[anchor.id]?.startAt == start.addingTimeInterval(3_600)
              && producer.database!.events[sibling.id]?.recurringEventId == "other-series",
              "Mac series undo carries member state and refuses changed sibling membership")
    } else {
        check(producer.database!.events[anchor.id]?.startAt == anchor.startAt
              && producer.database!.events[sibling.id]?.startAt == sibling.startAt,
              "Mac series move producer and undo consumer retain the full transaction snapshot")
    }
}
let oldDate = Date(timeIntervalSince1970: 1_795_132_800)
for intent in [false, true] {
    var original = initial
    original.someday = intent
    var live = original
    live.someday = !intent
    live.notes = "Remote notes"
    let model = AppModel()
    model.database!.tasks[initial.id] = live
    _ = model.save(original, original: original, somedayIntent: intent)
    check(model.database!.tasks[initial.id]?.someday == intent
          && model.database!.tasks[initial.id]?.notes == live.notes,
          "Mac save forwards explicit final Someday intent without clobbering untouched fields")
    model.database!.tasks[initial.id] = live
    _ = model.save(original, original: original)
    check(model.database!.tasks[initial.id]?.someday == live.someday,
          "Mac save preserves an untouched concurrent Someday decision")
}
let newDate = oldDate.addingTimeInterval(4 * 86_400)
for date in [oldDate, newDate] {
    var original = initial
    original.dueAt = oldDate
    original.deadlineType = .soft
    var live = original
    live.someday = true
    live.dueAt = nil
    live.deadlineType = .none
    live.notes = "Remote notes"
    var draft = original
    draft.dueAt = date
    let model = AppModel()
    model.database!.tasks[initial.id] = live
    _ = model.save(draft, original: original, somedayIntent: false, dateEdits: [.due])
    check(model.database!.tasks[initial.id]?.dueAt == date
          && model.database!.tasks[initial.id]?.deadlineType == .soft
          && model.database!.tasks[initial.id]?.notes == live.notes,
          "Mac save forwards an explicit due choice and its deadline policy after concurrent Someday")
}
for localSomeday in [false, true] {
    var toggled = initial
    toggled.someday = true
    toggled.dueAt = nil
    toggled.pinnedStart = nil
    toggled.deadlineType = .none
    var editor = TaskEditorSheet(
        draft: toggled, original: initial, isNew: true, somedayIntent: true, dateEdits: [.due, .pin],
        hasDue: false, dueAt: oldDate, startAt: oldDate, pinnedStart: oldDate)
    if localSomeday {
        editor.model.editorQuickAddDraft = QuickAddParser.parse(
            "Local ^none", now: oldDate, calendar: Calendar(identifier: .gregorian))
    }
    let parsedProject = Project(id: "parsed-project", name: "Parsed", createdAt: oldDate, updatedAt: oldDate)
    editor.model.projects = [parsedProject]
    editor.useParsed(TaskDraft(title: "Dated AI draft", durationMinutes: 30, deadlineType: .soft, dueAt: newDate,
                               context: .errand, projectId: parsedProject.id, attention: .shared))
    let prepared = editor.saved()
    check(prepared.context == .errand && prepared.projectId == parsedProject.id && prepared.attention == .shared,
          "Mac Use this applies live AI scheduling fields alongside the Someday decision")
    let model = AppModel()
    _ = model.save(prepared, original: nil, somedayIntent: editor.somedayIntent, dateEdits: editor.dateEdits)
    check(editor.somedayIntent == nil && editor.dateEdits.isEmpty,
          "Mac draft replacement discards superseded toggle and date merge metadata")
    check(model.database!.tasks[initial.id]?.someday == localSomeday
          && model.database!.tasks[initial.id]?.dueAt == (localSomeday ? nil : newDate),
          "Mac toggle-on then Use this saves the final dated/local-explicit draft, not stale intent")
}
let section = TaskRecurrenceSection()
section.recurrence = TaskRecurrence(frequency: .week, timeZone: "UTC", startDate: "")
section.recurrence!.startDate = section.recurrence!.dateString(for: oldDate)
section.changedAnchor(newDate)
var recurringDraft = initial
recurringDraft.recurrence = section.recurrence
var editor = TaskEditorSheet(draft: recurringDraft, original: initial, dueAt: newDate, startAt: oldDate, pinnedStart: oldDate)
check(editor.saved().dueAt == newDate, "due date chosen after enabling repeats survives editor preparation")
let explicitDate = newDate.addingTimeInterval(7 * 86_400)
section.startDateEdited = true
section.recurrence!.startDate = section.recurrence!.dateString(for: explicitDate)
section.changedAnchor(newDate)
editor.draft.recurrence = section.recurrence
check(editor.saved().dueAt == explicitDate, "explicit recurrence Starts remains authoritative")
var rawProject = project
rawProject.name = "Original project "
rawProject.notes = "Original notes "
rawProject.nextStep = "Original step "
rawProject.weeklyMinutes = 0
var projectDraft = rawProject
projectDraft.parallel = true
let projectSave = AppModel()
_ = projectSave.save(project: projectDraft, original: rawProject)
let submittedProject = projectSave.database!.projectDraft!
check(submittedProject.name == rawProject.name && submittedProject.notes == rawProject.notes
      && submittedProject.nextStep == rawProject.nextStep,
      "Mac project caller preserves untouched raw text before store diff")
check(submittedProject.weeklyMinutes == 0, "Mac project caller preserves untouched zero weekly minutes")
projectDraft.name = " Changed name "
projectDraft.notes = " \n "
projectDraft.nextStep = " Changed step "
_ = projectSave.save(project: projectDraft, original: rawProject)
check(projectSave.database!.projectDraft?.name == "Changed name"
      && projectSave.database!.projectDraft?.notes == nil
      && projectSave.database!.projectDraft?.nextStep == "Changed step",
      "Mac project caller still normalizes changed text and explicit clears")
_ = projectSave.save(project: rawProject)
check(projectSave.database!.projectDraft?.name == "Original project"
      && projectSave.database!.projectDraft?.weeklyMinutes == nil,
      "Mac new project caller still normalizes text and weekly minutes")
var rawEvent = event
rawEvent.summary = "Original summary "
rawEvent.location = "Original room "
rawEvent.description = "Original description "
var liveEvent = rawEvent
liveEvent.location = "Remote room"
liveEvent.description = "Remote description"
var eventDraft = rawEvent
eventDraft.summary = " Changed summary "
let eventPreparers: [(String, (CalendarEvent, CalendarEvent, Bool) -> CalendarEvent)] = [
    ("Mac", { EventEditorSheet(draft: $0, original: $1, isNew: $2).prepared() }),
    ("iPhone", { EventEditorView(draft: $0, original: $1, isNew: $2).prepared() }),
]
for (platform, prepare) in eventPreparers {
    let model = AppModel()
    model.database!.events[event.id] = liveEvent
    _ = model.save(event: prepare(eventDraft, rawEvent, false), original: rawEvent)
    check(model.database!.events[event.id]?.location == liveEvent.location
          && model.database!.events[event.id]?.description == liveEvent.description,
          "\(platform) event caller preserves remote changes to untouched whitespace-bearing fields")
    var clear = eventDraft
    clear.location = " \n "
    let submitted = prepare(clear, rawEvent, false)
    check(submitted.summary == "Changed summary" && submitted.location == nil,
          "\(platform) event caller still normalizes changed text and explicit clears")
    let new = prepare(rawEvent, rawEvent, true)
    check(new.summary == "Original summary" && new.location == "Original room"
          && new.description == "Original description",
          "\(platform) new event caller still normalizes all text")
}
var rawTask = initial
rawTask.title = "Original title "
rawTask.source = TaskSource(url: "https://example.com/old", title: "Original source ", kind: .web)
rawTask.dueAt = oldDate
rawTask.deadlineType = .none
var taskDraft = rawTask
taskDraft.priority = .high
let taskPreparers: [(String, (TaskItem, TaskItem, String, String, Bool) -> TaskItem)] = [
    ("Mac", { draft, original, url, title, isNew in
        TaskEditorSheet(draft: draft, original: original, isNew: isNew, sourceURL: url, sourceTitle: title,
                        hasDue: draft.dueAt != nil, dueAt: draft.dueAt ?? oldDate,
                        hasStart: draft.startAt != nil, startAt: draft.startAt ?? oldDate,
                        hasPinnedStart: draft.pinnedStart != nil, pinnedStart: draft.pinnedStart ?? oldDate).saved()
    }),
    ("iPhone", { TaskEditorView(draft: $0, original: $1, isNew: $4, sourceURL: $2, sourceTitle: $3).saved() }),
]
for (platform, prepare) in taskPreparers {
    let submitted = prepare(taskDraft, rawTask, rawTask.source!.url, rawTask.source!.title, false)
    check(submitted.title == rawTask.title && submitted.source == rawTask.source,
          "\(platform) task caller preserves untouched title and raw source metadata")
    check(submitted.dueAt == rawTask.dueAt && submitted.deadlineType == rawTask.deadlineType,
          "\(platform) task caller preserves untouched none-deadline with persisted due date")
    var live = rawTask
    live.title = "Remote title"
    live.source = TaskSource(url: "https://example.com/remote", title: "Remote source", kind: .web)
    live.dueAt = newDate
    live.deadlineType = .hard
    let database = AppDatabase()
    database.tasks[live.id] = live
    try database.saveTask(submitted, original: rawTask)
    check(database.tasks[live.id]?.title == live.title && database.tasks[live.id]?.source == live.source
          && database.tasks[live.id]?.dueAt == live.dueAt && database.tasks[live.id]?.deadlineType == live.deadlineType,
          "\(platform) task caller does not turn normalization into remote field clobbers")
    var changed = taskDraft
    changed.title = " Changed title "
    changed.deadlineType = .soft
    let edited = prepare(changed, rawTask, "", "", false)
    check(edited.title == "Changed title" && edited.source == nil && edited.deadlineType == .soft,
          "\(platform) task caller still normalizes changed title and source clear")
    let new = prepare(rawTask, rawTask, rawTask.source!.url, rawTask.source!.title, true)
    check(new.title == "Original title" && new.source?.title == "Original source",
          "\(platform) new task caller still normalizes title and source")
}
let completingDraft = TaskEditorView(draft: taskDraft, original: rawTask,
                                     sourceURL: rawTask.source!.url, sourceTitle: rawTask.source!.title)
check(completingDraft.completed().title == rawTask.title,
      "iPhone editor completion preserves an untouched whitespace-bearing title")
exit(failed == 0 ? 0 : 1)
'''
uses_mutations = 'AppDatabase.TaskMutation' in undo
tests = tests.replace('__NO_EDIT_RESULT__',
                      'return AppDatabase.TaskMutation(before: initial, after: initial)' if uses_mutations else '')
tests = tests.replace('__PRIORITY_RESULT__',
                      'return AppDatabase.TaskMutation(before: before, after: model.database!.tasks[initial.id]!)' if uses_mutations else '')
tests = tests.replace('__INTERLEAVED_RESULT__',
                      'return AppDatabase.TaskMutation(before: before, after: interleaved.database!.tasks[initial.id]!)' if uses_mutations else '')

ios_model = r'''
struct LocalWriteError: Error { init(_ message: String) {} }
struct Animation {
    static func easeInOut(duration: Double) -> Animation { Animation() }
}
func withAnimation(_ animation: Animation, _ body: () -> Void) { body() }
struct BloomingTask { let task: TaskItem; let index: Int }
enum Formatting {
    static func duration(minutes: Int) -> String { "\(minutes)m" }
    static func time(_ date: Date) -> String { "time" }
}
final class AppModel {
    static let bloomDuration: Duration = .milliseconds(150)
    var database: AppDatabase? = AppDatabase()
    var openTasks: [TaskItem] = []
    var blooming: [String: BloomingTask] = [:]
    var completionCount = 0
    var calendar = Calendar(identifier: .gregorian)
    var now = Date()
    var taskListCalendar: Calendar { calendar }
    var today: Date { calendar.startOfDay(for: Date()) }
    var triageSuggestions: [String: Int] = [:]
    var ghostIds: Set<String> = ["ghost"]
    var triageAttempted: Set<String> = []
    var toasts: [Toast] = []
    func dismissToast() {}
    func removeGhosts(ids: [String]) { ghostIds.subtract(ids) }
    func showToast(_ toast: Toast) { toasts.append(toast) }
    func storedVersion(of task: TaskItem) -> TaskItem { database!.tasks[task.id] ?? task }
    func recordGhosts(for task: TaskItem, includeUpcoming: Bool) -> [String] { [] }
    func perform(_ change: (AppDatabase) throws -> Void) throws { try change(database!) }
    func write(_ change: (AppDatabase) throws -> Void) -> Bool {
        do { try change(database!); return true } catch { return false }
    }
}
'''
ios_tests = tests[tests.index('func task()'):tests.index('let model = AppModel()')] + r'''
let model = AppModel()
let initial = task()
var changed = initial
changed.completedMinutes = 15
let toast = Toast(message: "Worked", systemImage: "checkmark", style: .info,
                  undo: TaskUndo(from: initial, to: changed), ghostIds: ["ghost"])
var live = changed
live.completedMinutes = 20
model.database!.tasks[initial.id] = live
model.undo(toast)
check(model.ghostIds.contains("ghost"), "failed undo preserves calendar ghost blocks")
model.database!.tasks[initial.id] = changed
model.database!.tasks[initial.id]?.notes = "Remote notes"
model.undo(toast)
check(!model.ghostIds.contains("ghost"), "successful undo removes calendar ghost blocks")
check(model.database!.tasks[initial.id]?.notes == "Remote notes", "iPhone undo preserves unrelated remote edits")
check(model.database!.tasks[initial.id]?.completedMinutes == 0, "iPhone undo restores only action fields")
let completion = AppModel()
completion.database!.tasks[initial.id] = initial
completion.database!.beforeComplete = { completion.database!.tasks[initial.id]?.categoryId = "remote-category" }
completion.complete(initial)
completion.undo(completion.toasts.last!)
check(completion.database!.tasks[initial.id]?.categoryId == "remote-category",
      "iPhone completion undo preserves a concurrent remote category change")
check(completion.database!.tasks[initial.id]?.completedAt == nil,
      "iPhone completion undo reopens the task")
let absentCompletion = AppModel()
absentCompletion.complete(initial)
check(absentCompletion.completionCount == 0 && absentCompletion.toasts.isEmpty,
      "iPhone completion of an absent task has no success feedback")
let editorCompletion = AppModel()
editorCompletion.database!.tasks[initial.id] = initial
var editorDraft = initial
editorDraft.title = "Edited title"
editorDraft.categoryId = "edited-category"
editorCompletion.complete(editorDraft, original: initial)
editorCompletion.undo(editorCompletion.toasts.last!)
check(editorCompletion.database!.tasks[initial.id]?.title == initial.title
      && editorCompletion.database!.tasks[initial.id]?.categoryId == initial.categoryId,
      "iPhone editor completion undo reverses all edited fields together")
for intent in [false, true] {
    var original = initial
    original.someday = intent
    var live = original
    live.someday = !intent
    live.notes = "Remote notes"
    let model = AppModel()
    model.database!.tasks[initial.id] = live
    model.complete(original, original: original, somedayIntent: intent)
    check(model.database!.tasks[initial.id]?.someday == intent
          && model.database!.tasks[initial.id]?.notes == live.notes,
          "iPhone editor completion forwards final Someday intent without clobbering untouched fields")
}
let due = Date(timeIntervalSince1970: 1_800_000_000)
var dated = initial
dated.dueAt = due
dated.deadlineType = .hard
var deferred = dated
deferred.someday = true
deferred.dueAt = nil
deferred.deadlineType = .none
let datedCompletion = AppModel()
datedCompletion.database!.tasks[initial.id] = deferred
datedCompletion.complete(dated, original: dated, somedayIntent: false, dateEdits: [.due])
check(datedCompletion.database!.tasks[initial.id]?.dueAt == due
      && datedCompletion.database!.tasks[initial.id]?.deadlineType == .hard,
      "iPhone editor completion forwards a same-value due choice and its deadline policy")
let actions: [(String, (AppModel, TaskItem) -> Void)] = [
    ("pin", { $0.pin($1, at: Date()) }),
    ("progress", { $0.doneForNow($1, minutes: 10) }),
    ("tomorrow", { $0.pushToTomorrow($1) }),
    ("move", { $0.move($1, to: TaskCategory(id: "destination", name: "Destination", scheduleId: "work", createdAt: Date(), updatedAt: Date())) }),
]
for (name, action) in actions {
    let model = AppModel()
    model.database!.tasks[initial.id] = initial
    model.database!.beforeSave = { model.database!.tasks[initial.id]?.notes = "Concurrent remote notes" }
    action(model, initial)
    check(model.database!.tasks[initial.id]?.notes == "Concurrent remote notes",
          "iPhone \(name) preserves a sync update before the write transaction")
}
let projectModel = AppModel()
let rawProject = Project(id: "project", name: "Original project ", notes: "Original notes ",
                         nextStep: "Original step ", weeklyMinutes: 0, createdAt: Date(), updatedAt: Date())
var projectDraft = rawProject
projectDraft.parallel = true
try projectModel.saveProject(projectDraft, original: rawProject)
let submitted = projectModel.database!.projectDraft!
check(submitted.name == rawProject.name && submitted.notes == rawProject.notes
      && submitted.nextStep == rawProject.nextStep,
      "iPhone project caller preserves untouched raw text before store diff")
check(submitted.weeklyMinutes == 0, "iPhone project caller preserves untouched zero weekly minutes")
projectDraft.name = " Changed name "
projectDraft.notes = " \n "
projectDraft.nextStep = " Changed step "
try projectModel.saveProject(projectDraft, original: rawProject)
check(projectModel.database!.projectDraft?.name == "Changed name"
      && projectModel.database!.projectDraft?.notes == nil
      && projectModel.database!.projectDraft?.nextStep == "Changed step",
      "iPhone project caller still normalizes changed text and explicit clears")
try projectModel.saveProject(rawProject)
check(projectModel.database!.projectDraft?.name == "Original project"
      && projectModel.database!.projectDraft?.weeklyMinutes == nil,
      "iPhone new project caller still normalizes text and weekly minutes")
exit(failed == 0 ? 0 : 1)
'''

push_concurrency_tests = r'''
for policy in [DeadlineType.soft, .hard] {
    for movesDue in [false, true] {
        let model = AppModel()
        var original = task()
        original.dueAt = Date().addingTimeInterval(movesDue ? -86_400 : 604_800)
        original.deadlineType = policy
        model.database!.tasks[original.id] = original
        __SELECT__
        var deferred = original
        deferred.someday = true
        deferred.dueAt = nil
        deferred.deadlineType = .none
        deferred.notes = "Concurrent Someday notes"
        model.database!.beforeSave = { model.database!.tasks[original.id] = deferred }
        __PUSH__
        let saved = model.database!.tasks[original.id]!
        check(!saved.someday && saved.startAt != nil && saved.notes == deferred.notes,
              "__PLATFORM__ tomorrow wins over concurrent Someday without clobbering notes")
        check(movesDue ? (saved.dueAt != nil && saved.deadlineType == policy)
                       : (saved.dueAt == nil && saved.deadlineType == .none),
              "__PLATFORM__ tomorrow moves due with its policy only when it adjusts that date")
    }
}
'''
tests = tests.replace('exit(failed == 0 ? 0 : 1)',
                      push_concurrency_tests.replace('__SELECT__', 'model.selectedTask = original')
                      .replace('__PUSH__', 'model.snoozeSelection()').replace('__PLATFORM__', 'Mac')
                      + 'exit(failed == 0 ? 0 : 1)')
ios_tests = ios_tests.replace('exit(failed == 0 ? 0 : 1)',
                              push_concurrency_tests.replace('__SELECT__', '')
                              .replace('__PUSH__', 'model.pushToTomorrow(original)').replace('__PLATFORM__', 'iPhone')
                              + 'exit(failed == 0 ? 0 : 1)')

swiftc = shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
with tempfile.TemporaryDirectory(prefix='florida-app-writes-') as directory:
    work = Path(directory)
    core = sorted((ROOT / 'apple/FloridaCore/Sources/FloridaCore').rglob('*.swift'))
    subprocess.run([swiftc, '-emit-library', '-emit-module', '-module-name', 'FloridaKit',
                    *map(str, core), '-o', str(work / 'libFloridaKit.so')], cwd=work, check=True)
    main = work / 'main.swift'
    main.write_text(harness + types + '\nextension AppModel {\n' + methods + '\n}\n' + editor_harness + tests)
    subprocess.run([swiftc, '-I', directory, '-L', directory, '-lFloridaKit', str(main), '-o', str(work / 'tests')], check=True)
    result = subprocess.run([str(work / 'tests')], env={**os.environ, 'LD_LIBRARY_PATH': directory})
    ios = work / 'ios.swift'
    ios.write_text(harness[:harness.index('enum Item:')] + ios_model
                   + source('apple/iOS/Support/Toast.swift')
                   + '\nextension AppModel {\n' + method(source('apple/iOS/App/AppModel+InboxTriage.swift'), 'refreshTaskDateState') + '\n}\n'
                   + '\nextension AppModel {\n' + method(source('apple/iOS/App/AppModel+Writes.swift'), 'undo') + '\n}\n'
                   + '\nextension AppModel {\n' + method(source('apple/iOS/App/AppModel+Actions.swift'), 'complete') + '\n}\n'
                   + '\nextension AppModel {\n' + method(source('apple/iOS/App/AppModel+Actions.swift'), 'doneForNow') + '\n}\n'
                   + '\nextension AppModel {\n' + method(source('apple/iOS/App/AppModel+Actions.swift'), 'pushToTomorrow') + '\n}\n'
                   + '\nextension AppModel {\n' + method(source('apple/iOS/App/AppModel+Joy.swift'), 'pin') + '\n}\n'
                   + '\nextension AppModel {\n' + method(source('apple/iOS/App/AppModel+Categories.swift'), 'move') + '\n}\n'
                   + '\nextension AppModel {\n' + method(source('apple/iOS/App/AppModel+Plan.swift'), 'saveProject')
                   + '\n' + method(source('apple/iOS/App/AppModel+Plan.swift'), 'trimmedOrNil') + '\n}\n'
                   + ios_tests)
    subprocess.run([swiftc, '-I', directory, '-L', directory, '-lFloridaKit', str(ios), '-o', str(work / 'ios-tests')], check=True)
    ios_result = subprocess.run([str(work / 'ios-tests')], env={**os.environ, 'LD_LIBRARY_PATH': directory})
    raise SystemExit(result.returncode or ios_result.returncode)
