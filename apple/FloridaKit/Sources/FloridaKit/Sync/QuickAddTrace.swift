import Foundation
import Synchronization

public final class QuickAddTrace: Sendable {
    private struct Session {
        let salt = UInt64.random(in: .min ... .max)
        var taskID: String?
        var lines: [String] = []
        var dropped = 0

        func describe(_ text: String) -> String {
            var tag = Hasher()
            tag.combine(salt)
            for unit in text.utf16 { tag.combine(unit) }
            let words = text.split(whereSeparator: \.isWhitespace)
            return "tag=\(String(UInt(bitPattern: tag.finalize()), radix: 16)) utf16=\(text.utf16.count) words=\(words.count) first=\(words.first?.utf16.count ?? 0)"
        }

        mutating func append(_ line: String) {
            if lines.count == 128 {
                lines.removeFirst()
                dropped += 1
            }
            lines.append(line)
        }
    }

    private let session = Mutex<Session?>(nil)

    public init() {}

    public func start() { session.withLock { $0 = Session() } }

    public var isCapturingInput: Bool {
        session.withLock { $0 != nil && $0?.taskID == nil }
    }

    public func report() -> String? {
        session.withLock { session in
            guard let session, !session.lines.isEmpty else { return nil }
            let id = session.taskID.flatMap(UUID.init(uuidString:))?.uuidString.lowercased() ?? "-"
            return (["Quick Add trace v1 · task=\(id) · dropped=\(session.dropped)"] + session.lines).joined(separator: "\n")
        }
    }

    public func input(
        _ stage: String, buffer: String, selection: NSRange, marked: Bool,
        replacement: String? = nil, range: NSRange? = nil
    ) {
        session.withLock { current in
            guard var value = current, value.taskID == nil else { return }
            var line = "\(stage) \(value.describe(buffer)) selection=\(selection.location):\(selection.length) marked=\(marked)"
            if let range { line += " range=\(range.location):\(range.length)" }
            if let replacement { line += " replacement[\(value.describe(replacement))]" }
            value.append(line)
            current = value
        }
    }

    public func preview(_ title: String) {
        session.withLock { current in
            guard let value = current, value.taskID == nil else { return }
            current?.append("preview \(value.describe(title))")
        }
    }

    public func submit(from control: String, mirror: String, title: String) {
        session.withLock { current in
            guard let value = current, value.taskID == nil else { return }
            current?.append("submit \(control) mirror[\(value.describe(mirror))] parsed[\(value.describe(title))]")
        }
    }

    public func track(taskID: String, title: String) {
        session.withLock { current in
            guard var value = current, value.taskID == nil else { return }
            value.taskID = taskID
            value.append("create \(value.describe(title))")
            current = value
        }
    }

    public func localSaveFailed(taskID: String) {
        session.withLock { current in
            guard current?.taskID == taskID else { return }
            current?.taskID = nil
            current?.append("local save failed")
        }
    }

    func request(taskID: String, operation: PendingWrite.Op, body: Data?) {
        session.withLock { current in
            guard var value = current, value.taskID == taskID else { return }
            let fields = body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let title = (fields?["title"] as? String).map(value.describe) ?? "no title"
            value.append("send \(operation.rawValue) \(title)")
            current = value
        }
    }

    func accepted(taskID: String, title: String) {
        session.withLock { current in
            guard var value = current, value.taskID == taskID else { return }
            value.append("accepted \(value.describe(title))")
            current = value
        }
    }
}
