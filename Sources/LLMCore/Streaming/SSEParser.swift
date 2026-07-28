import Foundation

/// A decoded Server-Sent Events record.
public struct SSEEvent: Equatable, Sendable {
    public let event: String?
    public let data: String
    public let id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }

    /// Whether the event is the OpenAI-compatible stream terminator.
    public var isDone: Bool { data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" }
}

/// Incrementally parses SSE records across arbitrary byte boundaries.
public struct SSEParser: Sendable {
    private var buffer = Data()
    private var eventName: String?
    private var eventID: String?
    private var dataLines: [String] = []

    public init() {}

    /// Consumes bytes and returns every complete event found in them.
    public mutating func append(_ data: Data) -> [SSEEvent] {
        buffer.append(data)
        var events: [SSEEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if let event = consume(line) { events.append(event) }
        }
        return events
    }

    /// Completes parsing at end-of-stream, accepting a final event without a blank line.
    public mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
            buffer.removeAll(keepingCapacity: false)
            if let event = consume(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))) {
                events.append(event)
            }
        }
        if let event = dispatch() { events.append(event) }
        return events
    }

    private mutating func consume(_ line: String) -> SSEEvent? {
        guard !line.isEmpty else { return dispatch() }
        guard !line.hasPrefix(":") else { return nil }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.first == " " { value.removeFirst() }
        switch field {
        case "event": eventName = value
        case "data": dataLines.append(value)
        case "id": eventID = value
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        guard !dataLines.isEmpty || eventName != nil else { return nil }
        let result = SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"), id: eventID)
        eventName = nil
        dataLines.removeAll(keepingCapacity: true)
        return result
    }
}
