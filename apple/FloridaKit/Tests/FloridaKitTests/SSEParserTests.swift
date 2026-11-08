import Foundation
import Testing
@testable import FloridaKit

@Suite struct SSEParserTests {
    @Test func parsesTheServersHandshakeAndChangeNotices() {
        var parser = SSEParser()
        let events = parser.feed("""
            event: connected
            data: {"at":"2026-11-08T10:00:00.000Z"}

            : ping

            event: changed
            data: {"reason":"scheduler"}


            """)
        #expect(events == [
            ServerSentEvent(event: "connected", data: "{\"at\":\"2026-11-08T10:00:00.000Z\"}"),
            ServerSentEvent(event: "changed", data: "{\"reason\":\"scheduler\"}"),
        ])
    }

    @Test func joinsMultipleDataLinesAndDefaultsTheEventName() {
        var parser = SSEParser()
        let events = parser.feed("data: first\ndata: second\ndata:\n\n")
        #expect(events == [ServerSentEvent(event: "message", data: "first\nsecond\n")])
    }

    @Test func dispatchesAcrossChunkBoundaries() {
        var parser = SSEParser()
        var events: [ServerSentEvent] = []
        for chunk in ["eve", "nt: chan", "ged\nda", "ta: {}", "\n", "\n", "data: tail\n\n"] {
            events += parser.feed(chunk)
        }
        #expect(events == [
            ServerSentEvent(event: "changed", data: "{}"),
            ServerSentEvent(event: "message", data: "tail"),
        ])
    }

    @Test func acceptsCRLFAndBareCRLineEndingsEvenWhenSplit() {
        var parser = SSEParser()
        var events = parser.feed("event: a\r\ndata: 1\r\n\r\n")
        #expect(events == [ServerSentEvent(event: "a", data: "1")])

        // CR at the end of one chunk, LF at the start of the next must count as one line end.
        events = parser.feed("event: b\r")
        #expect(events.isEmpty)
        events = parser.feed("\ndata: 2\r")
        #expect(events.isEmpty)
        events = parser.feed("\n\r\n")
        #expect(events == [ServerSentEvent(event: "b", data: "2")])

        events = parser.feed("data: 3\r\rdata: 4\r\r")
        #expect(events == [ServerSentEvent(data: "3"), ServerSentEvent(data: "4")])
    }

    @Test func ignoresCommentsRetryUnknownFieldsAndEventsWithoutData() {
        var parser = SSEParser()
        let events = parser.feed(": keep-alive\nretry: 5000\nfoo: bar\nevent: lonely\n\ndata: real\n\n")
        #expect(events == [ServerSentEvent(data: "real")])
    }

    @Test func tracksIdsAndTreatsFieldsWithoutColonsAsEmpty() {
        var parser = SSEParser()
        var events = parser.feed("id: 7\ndata: x\n\n")
        #expect(events == [ServerSentEvent(data: "x", id: "7")])

        // The id persists until replaced; a NUL in an id is ignored; "data" alone is an empty line of data.
        events = parser.feed("id: bad\u{0}\ndata\n\n")
        #expect(events == [ServerSentEvent(data: "", id: "7")])

        events = parser.feed("id: 8\ndata:  two spaces\n\n")
        #expect(events == [ServerSentEvent(data: " two spaces", id: "8")])
    }

    @Test func stripsALeadingByteOrderMarkOnce() {
        var parser = SSEParser()
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        var events = parser.feed(bom + Array("data: a\n\n".utf8))
        #expect(events == [ServerSentEvent(data: "a")])
        // A BOM later in the stream is just bytes of the field name, so the line is ignored.
        events = parser.feed(bom + Array("data: b\n\n".utf8))
        #expect(events.isEmpty)
    }
}
