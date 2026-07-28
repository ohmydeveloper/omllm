import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMCore
@testable import LLMAnthropic
import Testing

private enum MockTransportError: Error, Sendable {
    case missingResponse
}

private actor TransportRecorder {
    private var requests: [URLRequest] = []
    private var responses: [LLMTransportResponse]

    init(responses: [LLMTransportResponse] = []) {
        self.responses = responses
    }

    func send(_ request: URLRequest) throws -> LLMTransportResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw MockTransportError.missingResponse }
        return responses.removeFirst()
    }

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func allRequests() -> [URLRequest] {
        requests
    }
}

private struct MockTransport: LLMTransport {
    let recorder: TransportRecorder
    let streamChunks: [Data]

    init(
        responses: [LLMTransportResponse] = [],
        streamChunks: [Data] = []
    ) {
        recorder = TransportRecorder(responses: responses)
        self.streamChunks = streamChunks
    }

    func send(_ request: URLRequest) async throws -> LLMTransportResponse {
        try await recorder.send(request)
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.record(request)
                for chunk in streamChunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }
}

@Suite("Anthropic adapter")
struct AnthropicTests {
    @Test("configuration supplies API defaults")
    func configuration() {
        let configuration = AnthropicConfiguration(apiKey: "test", defaultModel: "claude-test")
        #expect(configuration.baseURL.absoluteString == "https://api.anthropic.com")
        #expect(configuration.apiVersion == "2023-06-01")
    }

    @Test("POST messages maps headers, system, tools, results, and generation settings")
    func generateRequest() async throws {
        let transport = MockTransport(responses: [successfulResponse()])
        let driver = makeDriver(transport: transport)
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["city": .object(["type": .string("string")])]),
        ])
        let request = LLMRequest(
            model: "claude-request",
            instructions: "Be concise",
            messages: [
                .user("Weather?"),
                .init(role: .assistant, content: [
                    .toolCall(.init(
                        id: "tool-1",
                        name: "weather",
                        arguments: .object(["city": .string("Paris")])
                    )),
                ]),
                .toolResult(toolCallID: "tool-1", content: "Unavailable", isError: true),
            ],
            options: .init(
                temperature: 0.25,
                topP: 0.8,
                maxOutputTokens: 321,
                stopSequences: ["STOP"]
            ),
            tools: [.init(name: "weather", description: "Get weather", inputSchema: schema)],
            toolChoice: .tool(named: "weather"),
            localMetadata: ["private": .string("must-not-leak")]
        )

        _ = try await driver.generate(request)
        let sent = try #require(await transport.recorder.allRequests().only)
        let body = try decodeBody(sent)

        #expect(sent.url?.absoluteString == "https://example.test/api/v1/messages")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "secret")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2024-01-01")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(body["model"] == .string("claude-request"))
        #expect(body["system"] == .string("Be concise"))
        #expect(body["max_tokens"] == .number(321))
        #expect(body["temperature"] == .number(0.25))
        #expect(body["top_p"] == .number(0.8))
        #expect(body["stop_sequences"] == .array([.string("STOP")]))
        #expect(body["messages"]?.arrayValue?[0]["role"] == .string("user"))
        #expect(body["messages"]?.arrayValue?[0]["content"]?.arrayValue?[0]["text"] == .string("Weather?"))
        #expect(body["messages"]?.arrayValue?[1]["content"]?.arrayValue?[0]["type"] == .string("tool_use"))
        #expect(body["messages"]?.arrayValue?[1]["content"]?.arrayValue?[0]["input"] == .object(["city": .string("Paris")]))
        #expect(body["messages"]?.arrayValue?[2]["role"] == .string("user"))
        #expect(body["messages"]?.arrayValue?[2]["content"]?.arrayValue?[0]["type"] == .string("tool_result"))
        #expect(body["messages"]?.arrayValue?[2]["content"]?.arrayValue?[0]["tool_use_id"] == .string("tool-1"))
        #expect(body["messages"]?.arrayValue?[2]["content"]?.arrayValue?[0]["is_error"] == .boolean(true))
        #expect(body["tools"]?.arrayValue?[0]["name"] == .string("weather"))
        #expect(body["tools"]?.arrayValue?[0]["description"] == .string("Get weather"))
        #expect(body["tools"]?.arrayValue?[0]["input_schema"] == schema)
        #expect(body["tool_choice"] == .object(["type": .string("tool"), "name": .string("weather")]))
        #expect(body["localMetadata"] == nil)
        #expect(body["private"] == nil)
    }

    @Test("maps a representative response with finish reason, usage, and metadata")
    func responseMapping() async throws {
        let wire = """
        {
          "id":"msg-1","type":"message","role":"assistant","model":"claude-response",
          "content":[
            {"type":"text","text":"Checking"},
            {"type":"tool_use","id":"tool-1","name":"weather","input":{"city":"Paris"}}
          ],
          "stop_reason":"tool_use","stop_sequence":null,
          "usage":{"input_tokens":12,"output_tokens":7,"cache_read_input_tokens":3}
        }
        """
        let transport = MockTransport(responses: [response(json: wire)])

        let result = try await makeDriver(transport: transport).generate(.text("Hi"))

        #expect(result.id == "msg-1")
        #expect(result.model == "claude-response")
        #expect(result.message.content == [
            .text("Checking"),
            .toolCall(.init(
                id: "tool-1",
                name: "weather",
                arguments: .object(["city": .string("Paris")])
            )),
        ])
        #expect(result.finishReason == .toolCalls)
        #expect(result.usage == .init(inputTokens: 12, outputTokens: 7))
        #expect(result.providerMetadata["usage_cache_read_input_tokens"] == .number(3))
    }

    @Test("split SSE chunks produce text, tool argument, usage, and completed events")
    func streamingEvents() async throws {
        let records = [
            sse("message_start", "{\"type\":\"message_start\",\"message\":{\"id\":\"msg-1\",\"model\":\"claude-stream\",\"usage\":{\"input_tokens\":7}}}"),
            sse("content_block_start", "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"),
            sse("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hel\"}}"),
            sse("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"lo\"}}"),
            sse("content_block_start", "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool-1\",\"name\":\"weather\",\"input\":{}}}"),
            sse("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"city\\\":\"}}"),
            sse("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"Paris\\\"}\"}}"),
            sse("message_delta", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":5}}"),
            sse("message_stop", "{\"type\":\"message_stop\"}"),
        ].joined()
        let transport = MockTransport(streamChunks: split(Data(records.utf8), every: 13))
        var events: [LLMEvent] = []

        for try await event in makeDriver(transport: transport).stream(.text("Hi")) {
            events.append(event)
        }

        #expect(events.count == 8)
        #expect(events[0] == .started(id: "msg-1", model: "claude-stream"))
        #expect(events[1] == .textDelta("Hel"))
        #expect(events[2] == .textDelta("lo"))
        #expect(events[3] == .toolCallStarted(id: "tool-1", name: "weather"))
        #expect(events[4] == .toolCallArgumentsDelta(id: "tool-1", jsonFragment: "{\"city\":"))
        #expect(events[5] == .toolCallArgumentsDelta(id: "tool-1", jsonFragment: "\"Paris\"}"))
        #expect(events[6] == .usage(.init(inputTokens: 7, outputTokens: 5)))
        guard case let .completed(completed) = events[7] else {
            Issue.record("Expected a completed event")
            return
        }
        #expect(completed.text == "Hello")
        #expect(completed.finishReason == .toolCalls)
        #expect(completed.usage == .init(inputTokens: 7, outputTokens: 5))
        #expect(completed.message.content.last == .toolCall(.init(
            id: "tool-1",
            name: "weather",
            arguments: .object(["city": .string("Paris")])
        )))

        let sent = try #require(await transport.recorder.allRequests().only)
        #expect(sent.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(try decodeBody(sent)["stream"] == .boolean(true))
    }

    @Test("maps HTTP error statuses", arguments: [
        (400, "context window exceeded", LLMError.contextLengthExceeded("context window exceeded")),
        (401, "bad key", LLMError.authenticationFailed("bad key")),
        (403, "forbidden", LLMError.permissionDenied("forbidden")),
        (404, "missing", LLMError.modelNotFound("missing")),
        (500, "down", LLMError.serverError(statusCode: 500, message: "down")),
    ])
    func statusErrors(status: Int, message: String, expected: LLMError) async {
        let wire = "{\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"\(message)\"}}"
        let transport = MockTransport(responses: [response(json: wire, statusCode: status)])

        await #expect(throws: expected) {
            try await makeDriver(transport: transport).generate(.text("Hi"))
        }
    }

    @Test("maps rate limit retry headers")
    func rateLimit() async {
        let transport = MockTransport(responses: [.init(
            data: Data("{\"error\":{\"message\":\"slow down\"}}".utf8),
            statusCode: 429,
            headers: ["Retry-After": "1.5"]
        )])

        await #expect(throws: LLMError.rateLimited(retryAfterSeconds: 1.5)) {
            try await makeDriver(transport: transport).generate(.text("Hi"))
        }
    }

    @Test("GET models follows every page and maps fields and metadata")
    func listModels() async throws {
        let first = """
        {"data":[{
          "id":"claude-a","display_name":"Claude A","created_at":"2025-01-02T03:04:05Z",
          "type":"model","custom":{"tier":"fast"}
        }],"has_more":true,"first_id":"claude-a","last_id":"page-token"}
        """
        let second = """
        {"data":[{"id":"claude-b","display_name":"Claude B","created_at":"2025-02-03T04:05:06Z","preview":true}],"has_more":false}
        """
        let transport = MockTransport(responses: [response(json: first), response(json: second)])

        let models = try await makeDriver(transport: transport).listModels()

        #expect(models.count == 2)
        #expect(models[0].model == "claude-a")
        #expect(models[0].displayName == "Claude A")
        #expect(models[0].ownedBy == "anthropic")
        #expect(models[0].createdAt == ISO8601DateFormatter().date(from: "2025-01-02T03:04:05Z"))
        #expect(models[0].metadata["type"] == .string("model"))
        #expect(models[0].metadata["custom"] == .object(["tier": .string("fast")]))
        #expect(models[0].metadata["id"] == nil)
        #expect(models[0].metadata["display_name"] == nil)
        #expect(models[0].metadata["created_at"] == nil)
        #expect(models[1].model == "claude-b")
        #expect(models[1].displayName == "Claude B")
        #expect(models[1].metadata["preview"] == .boolean(true))

        let requests = await transport.recorder.allRequests()
        #expect(requests.count == 2)
        #expect(requests[0].url?.absoluteString == "https://example.test/api/v1/models")
        #expect(requests[1].url?.absoluteString == "https://example.test/api/v1/models?after_id=page-token")
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "x-api-key") == "secret" })
        #expect(requests.allSatisfy { $0.httpBody == nil })
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private func makeDriver(transport: MockTransport) -> AnthropicDriver {
    AnthropicDriver(
        configuration: .init(
            apiKey: "secret",
            baseURL: URL(string: "https://example.test/api")!,
            apiVersion: "2024-01-01",
            defaultModel: "claude-default"
        ),
        transport: transport
    )
}

private func successfulResponse() -> LLMTransportResponse {
    response(json: "{\"id\":\"msg-0\",\"model\":\"claude-test\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\"}")
}

private func response(json: String, statusCode: Int = 200) -> LLMTransportResponse {
    .init(data: Data(json.utf8), statusCode: statusCode, headers: [:])
}

private func decodeBody(_ request: URLRequest) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
}

private func sse(_ event: String, _ data: String) -> String {
    "event: \(event)\ndata: \(data)\n\n"
}

private func split(_ data: Data, every size: Int) -> [Data] {
    stride(from: 0, to: data.count, by: size).map { offset in
        data.subdata(in: offset..<min(offset + size, data.count))
    }
}
