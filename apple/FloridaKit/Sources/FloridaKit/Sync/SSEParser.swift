import Foundation

/// One event from a `text/event-stream` response.
public struct ServerSentEvent: Hashable, Sendable {
    /// The `event:` field, or "message" when the server sent none.
    public var event: String
    /// The `data:` lines joined with "\n".
    public var data: String
    /// The last `id:` field seen on the stream at dispatch time, if any.
    public var id: String?

    public init(event: String = "message", data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental parser for the server-sent events wire format (WHATWG HTML § 9.2.6). Feed it the
/// response body in whatever chunks arrive; it returns the events that completed in each chunk.
///
/// Handles `event:`, `data:` (multiple lines joined with "\n"), `id:`, `retry:` (ignored),
/// comment lines starting with `:`, blank-line dispatch, and CRLF, LF or CR line endings, with
/// line ends split across chunks. An event is dispatched only when at least one `data:` line was
/// seen, as the specification requires. Pure: no I/O, no allocation beyond the partial line.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var pendingCarriageReturn = false
    private var isAtStreamStart = true

    private var eventType: String?
    private var dataLines: [String]?
    private var lastEventId: String?

    public init() {}

    /// Feeds raw body bytes and returns the events completed by them, in order.
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        for byte in bytes {
            if pendingCarriageReturn {
                pendingCarriageReturn = false
                if byte == 0x0A {
                    continue
                }
            }
            switch byte {
            case 0x0D:
                pendingCarriageReturn = true
                endLine(into: &events)
            case 0x0A:
                endLine(into: &events)
            default:
                line.append(byte)
            }
        }
        return events
    }

    /// Feeds a chunk of already-decoded text; equivalent to feeding its UTF-8 bytes.
    public mutating func feed(_ text: String) -> [ServerSentEvent] {
        feed(text.utf8)
    }

    private mutating func endLine(into events: inout [ServerSentEvent]) {
        var bytes = line
        line.removeAll(keepingCapacity: true)
        if isAtStreamStart {
            isAtStreamStart = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
                bytes.removeFirst(3)
            }
        }
        let text = String(decoding: bytes, as: UTF8.self)

        if text.isEmpty {
            if let dataLines {
                events.append(ServerSentEvent(
                    event: eventType ?? "message", data: dataLines.joined(separator: "\n"), id: lastEventId))
            }
            eventType = nil
            dataLines = nil
            return
        }
        if text.hasPrefix(":") {
            return
        }

        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") {
                value.removeFirst()
            }
        } else {
            field = Substring(text)
            value = ""
        }

        switch field {
        case "event":
            eventType = String(value)
        case "data":
            dataLines = (dataLines ?? []) + [String(value)]
        case "id":
            if !value.contains("\u{0}") {
                lastEventId = String(value)
            }
        default:
            // "retry" and unknown fields are ignored.
            break
        }
    }
}
