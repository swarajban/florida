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
    start = text.index(f'    func {name}(')
    end = text.index('\n    }', start) + len('\n    }')
    return text[start:end]


undo = source('apple/macOS/App/AppModel+Undo.swift')
writes = source('apple/macOS/App/AppModel+Writes.swift')
selection = source('apple/macOS/App/AppModel+Selection.swift')
types = undo[undo.index('struct UndoEntry'):undo.index('/// A short-lived label')]
methods = '\n'.join(method(undo, name) for name in ['recordingUndo', 'pushUndo', 'undo'])
methods += '\n' + '\n'.join(method(writes, name) for name in ['save', 'pinSelection', 'setPriority', 'deleteTask'])
methods += '\n' + method(source('apple/macOS/App/AppModel+Events.swift'), 'save')
methods += '\n' + method(source('apple/macOS/App/AppModel+Plan.swift'), 'save')
if 'var liveSelectedTask:' in selection:
    start = selection.index('    var liveSelectedTask:')
    methods += '\n' + selection[start:selection.index('\n    }', start) + len('\n    }')]

editor = source('apple/macOS/Tasks/TaskEditorSheet.swift')
start = editor.index('    private var preparedTask:')
prepared = editor[start:editor.index('\n    }', start) + len('\n    }')]
recurrence = source('apple/Design/TaskRecurrenceSection.swift')
anchor_update = method(recurrence.replace('private func ', 'func '), 'updateAnchor') if 'func updateAnchor(' in recurrence else ''
editor_harness = r'''
struct TaskEditorSheet {
    var draft: TaskItem
    var original: TaskItem
    var editedSource: TaskSource? { draft.source }
    var hasDue = true
    var dueAt: Date
    var hasStart = false
    var startAt: Date
    var hasPinnedStart = false
    var pinnedStart: Date
    func saved() -> TaskItem { preparedTask }
'''+ prepared + '\n}\n' + r'''
final class TaskRecurrenceSection {
    var recurrence: TaskRecurrence?
    var wasRecurring = false
    var startDateEdited = false
    func changedAnchor(_ date: Date) {
''' + ('        updateAnchor(date)' if anchor_update else '') + '\n    }\n' + anchor_update + '\n}\n'

harness = r'''
import FloridaKit
import Foundation

extension Priority { var displayName: String { rawValue } }
final class AppDatabase {
    var tasks: [String: TaskItem] = [:]
    func task(id: String) throws -> TaskItem? { tasks[id] }
    func saveTask(_ task: TaskItem) throws { tasks[task.id] = task }
    func saveTask(_ task: TaskItem, original: TaskItem?) throws { tasks[task.id] = task }
    func updateTask(id: String, _ update: (inout TaskItem) throws -> Bool) throws {
        guard var task = tasks[id], task.deletedAt == nil else { return }
        if try update(&task) { tasks[id] = task }
    }
    func deleteTask(id: String) throws { tasks[id]?.deletedAt = Date() }
    func restoreTask(_ snapshot: TaskItem) throws -> Bool {
        var restored = snapshot
        restored.deletedAt = nil
        restored.recurrence = nil
        tasks[snapshot.id] = restored
        return snapshot.recurrence != nil
    }
    func event(id: String) throws -> CalendarEvent? { nil }
    func saveEvent(_ event: CalendarEvent) throws {}
    func saveEvent(_ event: CalendarEvent, recurrence: EventRecurrence?) throws {}
    func saveEvent(_ event: CalendarEvent, original: CalendarEvent?, recurrence: EventRecurrence?) throws {}
    func saveProject(_ project: Project) throws {}
    func saveProject(_ project: Project, original: Project?) throws {}
    func moveEventSeries(instanceId: String, start: Date, end: Date) throws {}
}
enum Item: Equatable { case task(String), event(String) }
enum DateText {
    static func dayAndTime(_ date: Date, calendar: Calendar) -> String { "time" }
}
final class AppModel {
    static let undoLimit = 50
    var database: AppDatabase? = AppDatabase()
    var undoStack: [UndoEntry] = []
    var statusMessage: String?
    var selection: Item?
    var selectedTask: TaskItem?
    var selectedSuggestion: Int? { nil }
    var placementsByTask: [String: [Placement]] = [:]
    var calendar = Calendar(identifier: .gregorian)
    var ghosts: [String] = []
    func scheduleSync() {}
    func requireEditable(_ event: CalendarEvent) -> Bool { true }
    static func trimmedOrNil(_ text: String?) -> String? { text }
    func take(_ pick: Int) {}
    func neighbor(of item: Item) -> Item? { nil }
    func item(for task: TaskItem) -> Item { .task(task.id) }
    func showGhost(_ text: String, for duration: Duration = .seconds(1)) { ghosts.append(text) }
    static func quoted(_ text: String) -> String { text }
}
'''
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
model.database!.tasks[initial.id] = initial
model.selectedTask = initial
let start = Date(timeIntervalSince1970: 1_800_000_000)
model.placementsByTask[initial.id] = [Placement(id: "p", taskId: initial.id, startAt: start,
    endAt: start.addingTimeInterval(1800), pinned: false, computedAt: start)]
model.pinSelection(true)
model.setPriority(.high)
check(model.database!.tasks[initial.id]?.pinnedStart == start, "rapid priority after pin preserves the pin despite stale observation")
model.undoStack = []
try model.recordingUndo("No edit", taskId: initial.id) {}
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
    model.database!.tasks[initial.id]?.priority = .high
}
model.database!.tasks[initial.id]?.notes = "Remote notes"
model.undo()
check(model.database!.tasks[initial.id]?.notes == "Remote notes" && model.database!.tasks[initial.id]?.priority == .medium,
      "field-scoped undo keeps unrelated remote edits")
try model.recordingUndo("Priority", taskId: initial.id) {
    model.database!.tasks[initial.id]?.priority = .high
}
model.database!.tasks[initial.id]?.priority = .low
model.undo()
check(model.database!.tasks[initial.id]?.priority == .low, "undo refuses a field changed since the action")
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
let oldDate = Date(timeIntervalSince1970: 1_795_132_800)
let newDate = oldDate.addingTimeInterval(4 * 86_400)
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
exit(failed == 0 ? 0 : 1)
'''

ios_model = r'''
final class AppModel {
    var database: AppDatabase? = AppDatabase()
    var ghostIds: Set<String> = ["ghost"]
    var triageAttempted: Set<String> = []
    var toasts: [Toast] = []
    func dismissToast() {}
    func removeGhosts(ids: [String]) { ghostIds.subtract(ids) }
    func showToast(_ toast: Toast) { toasts.append(toast) }
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
exit(failed == 0 ? 0 : 1)
'''

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
                   + '\nextension AppModel {\n' + method(source('apple/iOS/App/AppModel+Writes.swift'), 'undo') + '\n}\n'
                   + ios_tests)
    subprocess.run([swiftc, '-I', directory, '-L', directory, '-lFloridaKit', str(ios), '-o', str(work / 'ios-tests')], check=True)
    ios_result = subprocess.run([str(work / 'ios-tests')], env={**os.environ, 'LD_LIBRARY_PATH': directory})
    raise SystemExit(result.returncode or ios_result.returncode)
