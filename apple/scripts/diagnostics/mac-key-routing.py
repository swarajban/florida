import hashlib
import json
import os
import pathlib
import shutil
import signal
import subprocess
from datetime import datetime


workspace = pathlib.Path(os.environ['GITHUB_WORKSPACE'])
output = workspace / 'diagnostic'
output.mkdir(exist_ok=True)
probe = workspace / 'candidate/apple/macOSUITests/KeyRoutingDiagnosticTests.swift'
baseline = '9d6d9e7bda36ac495026376390a582a3a73750a1'
results = {}


def instrument(root, relative, before, after):
    path = root / relative
    source = path.read_text()
    if source.count(before) != 1:
        raise RuntimeError(f'Expected one diagnostic insertion point: {relative}')
    path.write_text(source.replace(before, after, 1))


for label in ['baseline', 'candidate']:
    root = workspace / label
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    if label == 'baseline':
        if head != baseline:
            raise RuntimeError('Baseline checkout does not match the approved SHA')
        subprocess.run(['git', 'switch', '-c', 'diagnostic/main-key-routing'], cwd=root, check=True)
    destination = root / 'apple/macOSUITests/KeyRoutingDiagnosticTests.swift'
    if destination != probe:
        shutil.copyfile(probe, destination)
    instrument(root, 'apple/macOS/Keyboard/KeyEventMonitorView.swift',
               'let handled = MainActor.assumeIsolated {',
               '''let handled = MainActor.assumeIsolated {
                if UserDefaults.standard.bool(forKey: "demoData"), let model = box.model {
                    let host = box.view?.window
                    let key = NSApplication.shared.keyWindow
                    let responder = key?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                    NSLog("FLORIDA_KEY_DIAGNOSTIC host popover=\\(inEventPopover) code=\\(event.keyCode) event=\\(event.window?.windowNumber ?? -1) host=\\(host?.windowNumber ?? -1) key=\\(key?.windowNumber ?? -1) responder=\\(responder) selector=\\(host.map { SelectorInput.isEditing(in: $0) } ?? false) sheet=\\(model.isSheetOpen) detail=\\(model.eventDetailID != nil) jump=\\(model.jump != nil)")
                }''')
    instrument(root, 'apple/macOS/App/AppModel+Keyboard.swift',
               'func handleKeyDown(_ event: NSEvent, inEventPopover: Bool = false) -> Bool {',
               '''func handleKeyDown(_ event: NSEvent, inEventPopover: Bool = false) -> Bool {
        if UserDefaults.standard.bool(forKey: "demoData") {
            NSLog("FLORIDA_KEY_DIAGNOSTIC model code=\\(event.keyCode) popover=\\(inEventPopover) sheet=\\(isSheetOpen) detail=\\(eventDetailID != nil) jump=\\(jump != nil) typing=\\(NSApplication.shared.keyWindow?.firstResponder is NSTextView)")
        }''')
    instrument(root, 'apple/macOS/App/AppModel+Undo.swift', 'func undo() {', '''func undo() {
        if UserDefaults.standard.bool(forKey: "demoData") {
            NSLog("FLORIDA_KEY_DIAGNOSTIC undo entries=\\(undoStack.count) database=\\(database != nil)")
        }''')
    selectors = [
        '-only-testing:Florida-macOSUITests/KeyRoutingDiagnosticTests',
        '-only-testing:Florida-macOSUITests/SmokeTests/testJumpLabelsInBothAppearances',
    ]
    if label == 'candidate':
        selectors.append('-only-testing:Florida-macOSUITests/EditorRegressionTests/testSomedayUndoKeepsRemoteTitleAndDoesNotResurrectClosedTasks')
    print(f'{label}: {head}; selectors={selectors}', flush=True)
    diff = subprocess.check_output(['git', 'diff'], cwd=root, text=True)
    (output / f'{label}-instrumentation.txt').write_text(diff)
    environment = dict(os.environ, RETRY_FAILED_TESTS='0')
    started_at = datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S')
    timed_out = False
    with (output / f'{label}-test.log').open('w') as log:
        process = subprocess.Popen(['bash', 'apple/scripts/check.sh', 'macos', *selectors], cwd=root,
                                   env=environment, stdout=log, stderr=subprocess.STDOUT,
                                   text=True, start_new_session=True)
        try:
            code = process.wait(timeout=20 * 60)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                code = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                code = -1
        finally:
            subprocess.run(['pkill', '-x', 'Florida'], check=False)
            subprocess.run(['pkill', '-f', 'Florida-macOSUITests-Runner'], check=False)
            with (output / f'{label}-key-routing-system.log').open('w') as routing:
                try:
                    subprocess.run(['log', 'show', '--start', started_at, '--style', 'compact', '--predicate',
                                    'eventMessage BEGINSWITH "FLORIDA_KEY_DIAGNOSTIC"'],
                                   stdout=routing, stderr=subprocess.STDOUT, timeout=45)
                except subprocess.TimeoutExpired:
                    routing.write('\nRouting-log collection exceeded 45 seconds.\n')
    results[label] = {
        'head': head,
        'probe_sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
        'selectors': selectors,
        'exit_code': code,
        'timed_out': timed_out,
        'started_at': started_at,
    }
    (output / 'results.json').write_text(json.dumps(results, indent=2))
    print(f'{label}: exit_code={code}, timed_out={timed_out}', flush=True)

raise SystemExit(int(any(value['exit_code'] != 0 or value['timed_out'] for value in results.values())))
