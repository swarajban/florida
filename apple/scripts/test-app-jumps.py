#!/usr/bin/env python3
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description='Run portable regressions against the actual Mac edge-jump method.')
parser.add_argument('--ref', help='Read app sources from this git ref instead of the working tree.')
args = parser.parse_args()
path = 'apple/macOS/App/AppModel+Joy.swift'
source = (subprocess.check_output(['git', 'show', f'{args.ref}:{path}'], cwd=ROOT, text=True)
          if args.ref else (ROOT / path).read_text())
start = source.index('    func jumpToEdge(')
end = source.index('\n    }', start) + len('\n    }')
method = source[start:end]

harness = r'''
import Foundation

enum ItemID: Hashable {
    case task(String), suggestion(String), event(String)
}
enum Panel { case tasks, calendar }
struct GridLayout { var orderedItems: [ItemID] = [] }
final class AppModel {
    var focus: Panel = .tasks
    var orderedTaskItems: [ItemID] = []
    var gridLayout = GridLayout()
    var selection: ItemID?
    var paneItemsOnScreen: Set<ItemID> = []
    var taskPaneScrollRequest = 0
    var selections: [ItemID] = []
    var ghosts: [String] = []
    func select(_ item: ItemID) {
        selection = item
        selections.append(item)
    }
    func showGhost(_ text: String) { ghosts.append(text) }
}
extension AppModel {
''' + method + r'''
}

var failures = 0
var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if condition {
        print("PASS: \(message)")
    } else {
        failures += 1
        print("FAIL: \(message)")
    }
}

for target in [ItemID.task("last"), .suggestion("last")] {
    let model = AppModel()
    let first = ItemID.suggestion("first")
    model.orderedTaskItems = [first, target]
    model.gridLayout.orderedItems = [.event("calendar")]
    model.selection = first
    model.paneItemsOnScreen = [target]
    model.jumpToEdge(last: true)
    check(model.selection == target && model.selections == [target],
          "G selects the last pane item through select: \(target)")
    check(model.taskPaneScrollRequest == 1,
          "G requests scrolling despite stale visible cache: \(target)")
    model.jumpToEdge(last: true)
    check(model.selection == target && model.selections == [target, target],
          "repeated G keeps the same last selection: \(target)")
    check(model.taskPaneScrollRequest == 2,
          "repeated G issues a fresh scroll request: \(target)")
    check(model.paneItemsOnScreen == [target] && model.focus == .tasks && model.ghosts.isEmpty,
          "pane jumps preserve visibility cache, focus and feedback: \(target)")
}

for first in [ItemID.task("first"), .suggestion("first")] {
    let model = AppModel()
    model.orderedTaskItems = [first, .task("last")]
    model.selection = .task("last")
    model.paneItemsOnScreen = [first]
    model.jumpToEdge(last: false)
    check(model.selection == first && model.taskPaneScrollRequest == 1,
          "gg selects and requests the first item despite stale cache: \(first)")
    model.jumpToEdge(last: false)
    check(model.selection == first && model.taskPaneScrollRequest == 2,
          "repeated gg requests scrolling with unchanged selection: \(first)")
}

let calendar = AppModel()
calendar.focus = .calendar
calendar.orderedTaskItems = [.task("pane")]
calendar.gridLayout.orderedItems = [.event("first"), .task("last")]
calendar.taskPaneScrollRequest = 7
calendar.jumpToEdge(last: true)
calendar.jumpToEdge(last: false)
check(calendar.selections == [.task("last"), .event("first")],
      "calendar G and gg still select grid edges through select")
check(calendar.taskPaneScrollRequest == 7 && calendar.focus == .calendar && calendar.ghosts.isEmpty,
      "calendar jumps do not request task-pane scrolling or alter focus and feedback")

for focus in [Panel.tasks, .calendar] {
    for last in [false, true] {
        let model = AppModel()
        model.focus = focus
        if focus == .tasks {
            model.gridLayout.orderedItems = [.event("other-pane")]
        } else {
            model.orderedTaskItems = [.task("other-pane")]
        }
        model.selection = .task("existing")
        model.taskPaneScrollRequest = 4
        model.jumpToEdge(last: last)
        check(model.selection == .task("existing") && model.selections.isEmpty,
              "empty \(focus) edge last=\(last) preserves selection")
        check(model.taskPaneScrollRequest == 4 && model.ghosts == ["Nothing here"],
              "empty \(focus) edge last=\(last) gives feedback without requesting scroll")
    }
}
print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
'''

swiftc = shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
print(f'Testing jumpToEdge from {args.ref or "working tree"}', flush=True)
with tempfile.TemporaryDirectory(prefix='florida-app-jumps-') as directory:
    work = Path(directory)
    main = work / 'main.swift'
    main.write_text(harness)
    executable = work / 'tests'
    subprocess.run([swiftc, str(main), '-o', str(executable)], check=True)
    print('Compiled actual-source jump harness successfully', flush=True)
    raise SystemExit(subprocess.run([str(executable)]).returncode)
