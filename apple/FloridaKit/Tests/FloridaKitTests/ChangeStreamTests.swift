import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FloridaKit

@Suite struct ChangeStreamTests {
    @Test func backoffDoublesFromOneSecondToThirtyAndResets() {
        var backoff = ReconnectBackoff()
        var delays: [TimeInterval] = []
        for _ in 0..<7 {
            delays.append(backoff.nextDelay())
        }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30])
        backoff.reset()
        #expect(backoff.current == nil)
        #expect(backoff.nextDelay() == 1)
    }

    @Test func requestTargetsTheEventsEndpointWithBearerAuth() throws {
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "secret-token")
        let request = ChangeStream.request(for: config)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/events")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.timeoutInterval > 25)
    }

    @Test func cancelFinishesTheEventStream() async {
        let config = ServerConfig(baseURL: URL(string: "https://florida.example.test")!, token: "secret-token")
        let stream = ChangeStream(config: config)
        stream.cancel()
        var count = 0
        for await _ in stream.events {
            count += 1
        }
        #expect(count == 0)
    }
}
