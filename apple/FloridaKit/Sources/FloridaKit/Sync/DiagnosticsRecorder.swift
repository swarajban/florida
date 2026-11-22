import Foundation
import Synchronization

public final class DiagnosticsRecorder: Sendable {
    public static let shared = DiagnosticsRecorder()

    public enum Field: Sendable {
        case value(String)
        case redactedText(String)
        case text(String)
    }

    public struct Metadata: Sendable {
        let device: String
        let serverHost: String?
        let syncState: String
        let pending: Int
        let rejected: Int

        public init(device: String, serverURL: URL?, syncState: String, pending: Int, rejected: Int) {
            self.device = device
            self.serverHost = serverURL?.host
            self.syncState = syncState
            self.pending = pending
            self.rejected = rejected
        }
    }

    public struct Status: Sendable {
        public let startedAt: Date
        public let elapsed: TimeInterval
        public let isRecording: Bool
        public let count: Int
    }

    private struct Event {
        let timestamp: Date
        let subsystem: String
        let name: String
        let fields: [String: String]
    }

    private struct Session {
        let id = UUID()
        let startedAt = Date()
        let began: ContinuousClock.Instant
        let includeText: Bool
        let salt = UInt64.random(in: .min ... .max)
        var excludedToken: String?
        var expiryTask: Task<Void, Never>?
        var stopped: ContinuousClock.Instant?
        var stopReason: String?
        var events: [Event] = []
        var dropped = 0

        mutating func append(_ subsystem: String, _ event: String, fields: [String: Field], capacity: Int) {
            let entry = Event(timestamp: Date(), subsystem: subsystem, name: event, fields: fields.mapValues(format))
            if events.count < capacity {
                events.append(entry)
            } else {
                events[dropped % capacity] = entry
                dropped += 1
            }
        }

        func format(_ field: Field) -> String {
            switch field {
            case .value(let value):
                return value
            case .redactedText(let text), .text(let text):
                if let excludedToken, !excludedToken.isEmpty, text.contains(excludedToken) {
                    return "[credential omitted]"
                }
                if text.range(of: Self.credentialPattern, options: .regularExpression) != nil {
                    return "[credential omitted]"
                }
                var tag = Hasher()
                tag.combine(salt)
                for unit in text.utf16 { tag.combine(unit) }
                let words = text.split(whereSeparator: \.isWhitespace)
                let summary = "tag=\(String(UInt(bitPattern: tag.finalize()), radix: 16)) utf16=\(text.utf16.count) words=\(words.count) first=\(words.first?.utf16.count ?? 0)"
                guard includeText, case .text = field else { return summary }
                let excerpt = String(decoding: text.utf16.prefix(512), as: UTF16.self)
                return "\(summary) text=\(excerpt)"
            }
        }

        private static let credentialPattern = #"(?i)(?:\b(?:authorization|bearer|access[_ -]?token|refresh[_ -]?token|id[_ -]?token|api[_ -]?(?:key|token)|client[_ -]?(?:secret|id)|password)\b|https?://\S+[@?]|\b(?:ya29\.|1//|GOCSPX-|AIza|eyJ)[A-Za-z0-9_./-]+|\.apps\.googleusercontent\.com|-----BEGIN )"#
    }

    private let active = Atomic(false)
    private let session = Mutex<Session?>(nil)
    private let capacity: Int
    private let limit: Duration
    private let clock: @Sendable () -> ContinuousClock.Instant

    public convenience init() {
        self.init(capacity: 512, limit: .seconds(900), clock: { .now })
    }

    init(capacity: Int, limit: Duration, clock: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.capacity = capacity
        self.limit = limit
        self.clock = clock
    }

    public func start(includeText: Bool = false, excludingToken: String? = nil) {
        session.withLock {
            $0?.expiryTask?.cancel()
            $0 = Session(began: clock(), includeText: includeText, excludedToken: excludingToken)
            let id = $0?.id
            $0?.expiryTask = Task.detached { [weak self, limit] in
                do { try await Task.sleep(for: limit) } catch { return }
                self?.endIfExpired(id)
            }
            active.store(true, ordering: .relaxed)
        }
    }

    private func endIfExpired(_ id: UUID?) {
        session.withLock {
            guard $0?.id == id else { return }
            expire(&$0, at: clock())
        }
    }

    public func stop() {
        session.withLock {
            let now = clock()
            expire(&$0, at: now)
            finish(&$0, at: now, reason: "manual")
        }
    }

    public func clear() {
        session.withLock {
            $0?.expiryTask?.cancel()
            $0 = nil
            active.store(false, ordering: .relaxed)
        }
    }

    private func expire(_ current: inout Session?, at now: ContinuousClock.Instant) {
        guard let deadline = current.map({ $0.began.advanced(by: limit) }), now >= deadline else { return }
        finish(&current, at: deadline, reason: "time-limit")
    }

    private func finish(_ current: inout Session?, at instant: ContinuousClock.Instant, reason: String) {
        guard current != nil, current?.stopped == nil else { return }
        current?.stopped = instant
        current?.stopReason = reason
        current?.excludedToken = nil
        current?.expiryTask?.cancel()
        current?.expiryTask = nil
        active.store(false, ordering: .relaxed)
    }

    public var isRecording: Bool {
        guard active.load(ordering: .relaxed) else { return false }
        return session.withLock {
            expire(&$0, at: clock())
            return $0 != nil && $0?.stopped == nil
        }
    }

    public var status: Status? {
        session.withLock {
            let now = clock()
            expire(&$0, at: now)
            return $0.map { value in
                let elapsed = value.began.duration(to: value.stopped ?? now).components
                return Status(startedAt: value.startedAt,
                    elapsed: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                    isRecording: value.stopped == nil, count: value.events.count)
            }
        }
    }

    public func record(_ subsystem: String, _ event: String, _ fields: @autoclosure () -> [String: Field] = [:]) {
        guard active.load(ordering: .relaxed) else { return }
        session.withLock { current in
            expire(&current, at: clock())
            guard current != nil, current?.stopped == nil else { return }
            current?.append(subsystem, event, fields: fields(), capacity: capacity)
        }
    }

    public func error(_ subsystem: String, _ event: String, _ error: any Error) {
        guard isRecording else { return }
        switch error {
        case SyncError.http(let status, _):
            record(subsystem, event, ["error": .value("http"), "status": .value(String(status))])
        case SyncError.unauthorized:
            record(subsystem, event, ["error": .value("unauthorized")])
        case SyncError.transport(let cause):
            record(subsystem, event, ["error": .value("transport"), "kind": .value(String(describing: type(of: cause)))])
        case SyncError.decoding:
            record(subsystem, event, ["error": .value("decoding")])
        default:
            record(subsystem, event, ["error": .value(String(describing: type(of: error)))])
        }
    }

    public func input(
        _ stage: String, buffer: String, selection: NSRange, marked: Bool,
        replacement: String? = nil, range: NSRange? = nil
    ) {
        guard isRecording else { return }
        var fields: [String: Field] = [
            "buffer": .redactedText(buffer), "selection": .value("\(selection.location):\(selection.length)"),
            "marked": .value(String(marked)),
        ]
        if let range { fields["range"] = .value("\(range.location):\(range.length)") }
        if let replacement { fields["replacement"] = .redactedText(replacement) }
        record("quick-add", stage, fields)
    }

    public func report(_ metadata: Metadata) -> String? {
        let snapshot = session.withLock {
            expire(&$0, at: clock())
            return $0
        }
        guard let snapshot else { return nil }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        let dates = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        func quote(_ value: String) -> String { value.debugDescription }
        let fields = "app=\(quote(version)) build=\(quote(build)) os=\(quote(ProcessInfo.processInfo.operatingSystemVersionString)) device=\(quote(metadata.device))"
        let sync = "server=\(quote(metadata.serverHost ?? "-")) sync=\(quote(metadata.syncState)) pending=\(metadata.pending) rejected=\(metadata.rejected)"
        let settings = "started=\(snapshot.startedAt.formatted(dates)) state=\(snapshot.stopReason ?? "recording") includeText=\(snapshot.includeText) limitSeconds=\(limit.components.seconds) capacity=\(capacity) events=\(snapshot.events.count) dropped=\(snapshot.dropped)"
        var lines = ["Florida diagnostics v2", fields, sync, settings]
        for i in snapshot.events.indices {
            let event = snapshot.events[(i + snapshot.dropped) % capacity]
            let fields = event.fields.sorted { $0.key < $1.key }.map { " \($0.key)=\(quote($0.value))" }.joined()
            lines.append("\(event.timestamp.formatted(dates)) \(event.subsystem).\(event.name)\(fields)")
        }
        return lines.joined(separator: "\n")
    }
}
