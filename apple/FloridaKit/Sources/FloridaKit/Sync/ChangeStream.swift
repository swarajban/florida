import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Exponential backoff for reconnecting a long-lived connection: the first retry waits
/// `minimum`, each later one doubles, capped at `maximum`; `reset()` after a healthy connection.
public struct ReconnectBackoff: Hashable, Sendable {
    public var minimum: TimeInterval
    public var maximum: TimeInterval
    /// The delay returned by the last `nextDelay()`, or nil since the last reset.
    public private(set) var current: TimeInterval?

    public init(minimum: TimeInterval = 1, maximum: TimeInterval = 30) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public mutating func nextDelay() -> TimeInterval {
        let delay = current.map { min($0 * 2, maximum) } ?? minimum
        current = delay
        return delay
    }

    public mutating func reset() {
        current = nil
    }
}

/// A long-lived `GET /api/events` connection. The server sends `connected` once, then `changed`
/// after every scheduler run or calendar sync; clients answer `changed` by calling
/// `SyncClient.sync()`. Reconnects with exponential backoff (1 s doubling to 30 s) when the
/// connection fails or ends, and stops on `cancel()` or when the stream is deallocated.
///
/// Networking is Darwin-only (`URLSession.bytes(for:)`); elsewhere `events` finishes immediately,
/// so the type exists everywhere FloridaKit builds.
public final class ChangeStream: Sendable {
    /// Every event the server sends, including `connected`; finishes after `cancel()`.
    public let events: AsyncStream<ServerSentEvent>
    private let task: Task<Void, Never>

    public init(config: ServerConfig, backoff: ReconnectBackoff = ReconnectBackoff()) {
        let (stream, continuation) = AsyncStream.makeStream(of: ServerSentEvent.self)
        events = stream
        #if canImport(Darwin)
        let request = Self.request(for: config)
        task = Task.detached {
            await Self.run(request: request, backoff: backoff, continuation: continuation)
            continuation.finish()
        }
        #else
        task = Task.detached {
            continuation.finish()
        }
        #endif
    }

    deinit {
        task.cancel()
    }

    /// Closes the connection and finishes `events`. Safe to call more than once.
    public func cancel() {
        task.cancel()
    }

    static func request(for config: ServerConfig) -> URLRequest {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("api/events"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        // The server pings every 25 s; wait well past that before treating silence as a dead link.
        request.timeoutInterval = 90
        return request
    }

    #if canImport(Darwin)
    private static func run(
        request: URLRequest, backoff: ReconnectBackoff, continuation: AsyncStream<ServerSentEvent>.Continuation
    ) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = .infinity
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var backoff = backoff
        while !Task.isCancelled {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                var parser = SSEParser()
                var chunk: [UInt8] = []
                for try await byte in bytes {
                    chunk.append(byte)
                    if byte == 0x0A || chunk.count >= 4096 {
                        for event in parser.feed(chunk) {
                            backoff.reset()
                            continuation.yield(event)
                        }
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                for event in parser.feed(chunk) {
                    continuation.yield(event)
                }
            } catch {
                if Task.isCancelled {
                    return
                }
            }
            // End of stream or failure: wait, then reconnect.
            do {
                try await Task.sleep(for: .seconds(backoff.nextDelay()))
            } catch {
                return
            }
        }
    }
    #endif
}
