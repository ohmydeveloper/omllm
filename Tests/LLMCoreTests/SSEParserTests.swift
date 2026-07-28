import Foundation
import LLMCore
import Testing

@Suite("SSEParser")
struct SSEParserTests {
    @Test("parses one event")
    func oneEvent() {
        var parser = SSEParser()

        #expect(parser.append(Data("event: update\nid: 7\ndata: hello\n\n".utf8)) == [
            SSEEvent(event: "update", data: "hello", id: "7"),
        ])
        #expect(parser.finish().isEmpty)
    }

    @Test("parses multiple events from one chunk")
    func multipleEvents() {
        var parser = SSEParser()
        let events = parser.append(Data("data: first\n\ndata: second\n\n".utf8))

        #expect(events == [SSEEvent(data: "first"), SSEEvent(data: "second")])
    }

    @Test("parses an event split at arbitrary byte boundaries")
    func splitChunks() {
        var parser = SSEParser()
        var events: [SSEEvent] = []

        for chunk in ["eve", "nt: mes", "sage\r\nda", "ta: Hel", "lo\r", "\n\r\n"] {
            events.append(contentsOf: parser.append(Data(chunk.utf8)))
        }

        #expect(events == [SSEEvent(event: "message", data: "Hello")])
    }

    @Test("accepts LF and CRLF records", arguments: ["\n", "\r\n"])
    func lineEndings(separator: String) {
        var parser = SSEParser()
        let input = "event: update\(separator)data: value\(separator)\(separator)"

        #expect(parser.append(Data(input.utf8)) == [SSEEvent(event: "update", data: "value")])
    }

    @Test("joins multiline data and ignores comments and unknown fields")
    func multilineDataAndComments() {
        var parser = SSEParser()
        let input = ": keepalive\nretry: 1000\nevent: message\ndata: first\ndata: second\n\n"

        #expect(parser.append(Data(input.utf8)) == [
            SSEEvent(event: "message", data: "first\nsecond"),
        ])
    }

    @Test("recognizes done events with surrounding whitespace")
    func doneEvent() throws {
        var parser = SSEParser()
        let event = try #require(parser.append(Data("data:  [DONE] \n\n".utf8)).first)

        #expect(event.isDone)
    }

    @Test("finish dispatches a final unterminated event")
    func finish() {
        var parser = SSEParser()

        #expect(parser.append(Data("id: final\ndata: tail".utf8)).isEmpty)
        #expect(parser.finish() == [SSEEvent(data: "tail", id: "final")])
    }
}
