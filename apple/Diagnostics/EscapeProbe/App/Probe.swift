import UIKit

@MainActor
final class ProbeTrace {
    static let shared = ProbeTrace()
    weak var textView: ProbeTextView?
    var commandInventory: [[String: Any]] = []
    private var beganCodes: [String: [String: Int]] = [:]
    private var entries: [String] = []

    func record(_ entry: String) {
        if entries.count < 256 { entries.append(entry) }
        print("[EscapeProbe] \(entry)")
    }

    func recordPresses(_ presses: Set<UIPress>, layer: String) {
        for press in presses {
            let code = press.key?.keyCode.rawValue ?? 0
            if press.phase == .began {
                beganCodes[layer, default: [:]][String(code), default: 0] += 1
            }
            record("\(layer) phase=\(press.phase.rawValue) code=\(code) modifiers=\(press.key?.modifierFlags.rawValue ?? 0)")
        }
    }

    var snapshot: String {
        let data: [String: Any] = [
            "firstResponder": textView?.isFirstResponder ?? false,
            "marked": textView?.markedTextRange != nil,
            "beganCodes": beganCodes,
            "commands": commandInventory,
            "trace": entries,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
              let string = String(data: json, encoding: .utf8) else { return "{}" }
        return string
    }
}

final class ProbeApplication: UIApplication {
    override func sendEvent(_ event: UIEvent) {
        if let event = event as? UIPressesEvent {
            ProbeTrace.shared.recordPresses(event.allPresses, layer: "application")
        }
        super.sendEvent(event)
    }

    override func sendAction(_ action: Selector, to target: Any?, from sender: Any?, for event: UIEvent?) -> Bool {
        ProbeTrace.shared.record("action selector=\(NSStringFromSelector(action)) target=\(target.map { String(describing: type(of: $0)) } ?? "nil")")
        let handled = super.sendAction(action, to: target, from: sender, for: event)
        ProbeTrace.shared.record("action result=\(handled)")
        return handled
    }

    override func accessibilityPerformEscape() -> Bool {
        ProbeTrace.shared.record("application accessibilityPerformEscape")
        return super.accessibilityPerformEscape()
    }
}

final class ProbeWindow: UIWindow {
    override func sendEvent(_ event: UIEvent) {
        if let event = event as? UIPressesEvent {
            ProbeTrace.shared.recordPresses(event.allPresses, layer: "window")
        }
        super.sendEvent(event)
    }

    override func accessibilityPerformEscape() -> Bool {
        ProbeTrace.shared.record("window accessibilityPerformEscape")
        return super.accessibilityPerformEscape()
    }
}

final class ProbeTextView: UITextView {
    override var keyCommands: [UIKeyCommand]? { [] }

    var defaultCommandInventory: [[String: Any]] {
        (super.keyCommands ?? []).map { command in
            [
                "selector": NSStringFromSelector(command.action),
                "escape": command.input == UIKeyCommand.inputEscape,
                "modifiers": command.modifierFlags.rawValue,
                "priority": command.wantsPriorityOverSystemBehavior,
            ]
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        ProbeTrace.shared.recordPresses(presses, layer: "textView")
        super.pressesBegan(presses, with: event)
    }

    override func accessibilityPerformEscape() -> Bool {
        ProbeTrace.shared.record("textView accessibilityPerformEscape")
        return super.accessibilityPerformEscape()
    }
}

final class ProbeStatusView: UIView {
    override var accessibilityValue: String? {
        get { ProbeTrace.shared.snapshot }
        set { super.accessibilityValue = newValue }
    }
}

final class ProbeController: UIViewController {
    private let textView = ProbeTextView()
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let status = ProbeStatusView()
        status.isAccessibilityElement = true
        status.accessibilityIdentifier = "probe-trace"
        status.accessibilityLabel = "Probe trace"
        textView.accessibilityIdentifier = "probe-input"
        textView.accessibilityLabel = "Probe input"
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.font = .systemFont(ofSize: 20)
        for child in [status, textView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            status.heightAnchor.constraint(equalToConstant: 44),
            textView.topAnchor.constraint(equalTo: status.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            textView.heightAnchor.constraint(equalToConstant: 140),
        ])
        ProbeTrace.shared.textView = textView
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        let focused = textView.becomeFirstResponder()
        ProbeTrace.shared.record("ready firstResponder=\(focused) rawTextViewCommands=true")
        ProbeTrace.shared.commandInventory = textView.defaultCommandInventory
        var responder: UIResponder? = textView
        while let current = responder {
            let commands = current.keyCommands ?? []
            let escapeSelectors = commands.filter { $0.input == UIKeyCommand.inputEscape }
                .map { "\(NSStringFromSelector($0.action)):modifiers=\($0.modifierFlags.rawValue)" }
            ProbeTrace.shared.record("responder=\(String(describing: type(of: current))) commands=\(commands.count) escapeSelectors=\(escapeSelectors)")
            responder = current.next
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        ProbeTrace.shared.record("controller accessibilityPerformEscape")
        return super.accessibilityPerformEscape()
    }
}

final class ProbeAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = ProbeWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ProbeController()
        self.window = window
        window.makeKeyAndVisible()
        return true
    }
}
