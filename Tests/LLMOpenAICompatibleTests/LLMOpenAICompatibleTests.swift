import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMCore
import LLMOpenAICompatible
import Testing

private actor RequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func last() -> URLRequest? {
        requests.last
    }

    func count() -> Int {
        requests.count
    }
}

private struct MockTransport: LLMTransport {
    let recorder: RequestRecorder
    let response: LLMTransportResponse
    let streamChunks: [Data]

    init(
        recorder: RequestRecorder = RequestRecorder(),
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: String = #"{"id":"response","choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#,
        streamChunks: [Data] = []
    ) {
        self.recorder = recorder
        response = LLMTransportResponse(
            data: Data(body.utf8),
            statusCode: statusCode,
            headers: headers
        )
        self.streamChunks = streamChunks
    }

    func send(_ request: URLRequest) async throws -> LLMTransportResponse {
        await recorder.record(request)
        return response
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

private let baseURL = URL(string: "https://example.test/v1")!

private func decodedBody(_ request: URLRequest) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
}

private func caughtError(_ operation: () async throws -> Void) async -> LLMError? {
    do {
        try await operation()
        return nil
    } catch {
        return error as? LLMError
    }
}

@Test("OpenAI preset uses Responses with its official endpoint and bearer authentication")
func openAIPresetResponsesRequestAndMapping() async throws {
    let transport = MockTransport(body: #"{"id":"resp-1","model":"gpt-4.1","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Hello"}]},{"type":"function_call","call_id":"call-1","name":"weather","arguments":"{\"city\":\"Paris\"}"}],"usage":{"input_tokens":4,"output_tokens":2}}"#)
    let driver = OpenAICompatibleDriver(
        configuration: .openAI(apiKey: "openai-secret", defaultModel: LLMModel("gpt-4.1")),
        transport: transport
    )
    let request = LLMRequest(
        instructions: "Be concise",
        messages: [.user("What is the weather?")],
        options: .init(temperature: 0.2, topP: 0.8, maxOutputTokens: 64),
        tools: [.init(name: "weather", description: "Get weather", inputSchema: .object(["type": .string("object")]))],
        toolChoice: .tool(named: "weather"),
        output: .jsonObject
    )

    let response = try await driver.generate(request)

    #expect(driver.configuration.dialect == .responses)
    #expect(driver.configuration.compatibility == .openAIResponses)
    let urlRequest = try #require(await transport.recorder.last())
    #expect(urlRequest.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(urlRequest.httpMethod == "POST")
    #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer openai-secret")

    let body = try decodedBody(urlRequest)
    #expect(body["model"] == .string("gpt-4.1"))
    #expect(body["instructions"] == .string("Be concise"))
    #expect(body["temperature"] == .number(0.2))
    #expect(body["top_p"] == .number(0.8))
    #expect(body["max_output_tokens"] == .number(64))
    #expect(body["input"]?.arrayValue?.first?["role"] == .string("user"))
    #expect(body["input"]?.arrayValue?.first?["content"]?.arrayValue?.first == .object([
        "type": .string("input_text"), "text": .string("What is the weather?")
    ]))
    #expect(body["tools"]?.arrayValue?.first?["type"] == .string("function"))
    #expect(body["tools"]?.arrayValue?.first?["name"] == .string("weather"))
    #expect(body["tool_choice"] == .object(["type": .string("function"), "name": .string("weather")]))
    #expect(body["text"]?["format"]?["type"] == .string("json_object"))
    #expect(body["messages"] == nil)

    #expect(response.id == "resp-1")
    #expect(response.model == LLMModel("gpt-4.1"))
    #expect(response.text == "Hello")
    #expect(response.finishReason == .toolCalls)
    #expect(response.usage == .init(inputTokens: 4, outputTokens: 2))
    #expect(response.message.content.last == .toolCall(.init(
        id: "call-1", name: "weather", arguments: .object(["city": .string("Paris")])
    )))
}

@Test("Responses streaming maps normal event payloads and sends a Responses stream request")
func responsesStreamingMapping() async throws {
    let chunks = [
        "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp-stream\",\"model\":\"gpt-4.1\"}}\n\n",
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n",
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp-stream\",\"model\":\"gpt-4.1\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}}\n\n",
    ].map { Data($0.utf8) }
    let transport = MockTransport(streamChunks: chunks)
    let driver = OpenAICompatibleDriver(
        configuration: .openAI(apiKey: "openai-secret", defaultModel: LLMModel("gpt-4.1")),
        transport: transport
    )

    var events: [LLMEvent] = []
    for try await event in driver.stream(.text("Hello")) {
        events.append(event)
    }

    #expect(events.count == 4)
    #expect(events[0] == .started(id: "resp-stream", model: "gpt-4.1"))
    #expect(events[1] == .textDelta("Hello"))
    #expect(events[2] == .usage(.init(inputTokens: 3, outputTokens: 2)))
    guard case let .completed(response) = try #require(events.last) else {
        Issue.record("Expected completed event")
        return
    }
    #expect(response.text.isEmpty)
    #expect(response.finishReason == .completed)

    let urlRequest = try #require(await transport.recorder.last())
    #expect(urlRequest.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(urlRequest.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    let body = try decodedBody(urlRequest)
    #expect(body["stream"] == .boolean(true))
    #expect(body["stream_options"] == nil)
}

@Test("Responses uses model listing and custom gateway request settings")
func responsesModelsAndCustomGateway() async throws {
    let modelsTransport = MockTransport(body: #"{"data":[{"id":"gpt-4.1"}]}"#)
    let modelsDriver = OpenAICompatibleDriver(
        configuration: .openAI(apiKey: "openai-secret"),
        transport: modelsTransport
    )
    let models = try await modelsDriver.listModels()
    #expect(models.map(\.model) == [LLMModel("gpt-4.1")])
    let modelsRequest = try #require(await modelsTransport.recorder.last())
    #expect(modelsRequest.url?.absoluteString == "https://api.openai.com/v1/models")
    #expect(modelsRequest.httpMethod == "GET")
    #expect(modelsRequest.value(forHTTPHeaderField: "Authorization") == "Bearer openai-secret")

    let gateway = URL(string: "https://gateway.example/api/v2")!
    let gatewayTransport = MockTransport(body: #"{"id":"resp-gateway","status":"completed","output":[]}"#)
    let gatewayDriver = OpenAICompatibleDriver(
        configuration: .init(
            baseURL: gateway,
            apiKey: "gateway-secret",
            defaultModel: "gateway-model",
            additionalHeaders: ["X-Gateway-Client": "omchat"],
            dialect: .responses,
            generationEndpointPath: "/openai/responses/",
            compatibility: .openAIResponses
        ),
        transport: gatewayTransport
    )
    _ = try await gatewayDriver.generate(.text("Hello"))
    let gatewayRequest = try #require(await gatewayTransport.recorder.last())
    #expect(gatewayRequest.url?.absoluteString == "https://gateway.example/api/v2/openai/responses")
    #expect(gatewayRequest.value(forHTTPHeaderField: "Authorization") == "Bearer gateway-secret")
    #expect(gatewayRequest.value(forHTTPHeaderField: "X-Gateway-Client") == "omchat")
}

@Test("Responses rejects stop sequences and seed before transport")
func responsesRejectUnsupportedOptions() async {
    let transport = MockTransport()
    let driver = OpenAICompatibleDriver(
        configuration: .openAI(apiKey: "openai-secret", defaultModel: LLMModel("gpt-4.1")),
        transport: transport
    )

    let stopError = await caughtError {
        _ = try await driver.generate(LLMRequest(messages: [.user("Hello")], options: .init(stopSequences: ["END"])))
    }
    let seedError = await caughtError {
        _ = try await driver.generate(LLMRequest(messages: [.user("Hello")], options: .init(seed: 42)))
    }

    #expect(stopError == .unsupportedFeature("OpenAI Responses API does not support stop sequences"))
    #expect(seedError == .unsupportedFeature("OpenAI Responses API does not support seed"))
    #expect(await transport.recorder.count() == 0)
}

@Test("default compatibility options use chat-completions conventions")
func defaultCompatibilityOptions() {
    let options = CompatibilityOptions()
    #expect(options.instructionStyle == .system)
    #expect(options.supportsTools)
    #expect(options.supportsImages)
    #expect(options.supportsJSONObject)
    #expect(!options.supportsJSONSchema)
    #expect(!options.supportsStreamedUsage)
    #expect(options.supportsModelListing)
    #expect(options.maxTokenField == .maxTokens)
    #expect(options.authenticationStyle == .bearer)
    #expect(options.endpointPath == nil)
    #expect(options.modelsEndpointPath == "models")
}

@Test("generate uses the default endpoint, bearer auth, and maps the complete request body")
func generateRequestMapping() async throws {
    let transport = MockTransport()
    let compatibility = CompatibilityOptions(
        supportsJSONSchema: true,
        maxTokenField: .maxCompletionTokens
    )
    let driver = OpenAICompatibleDriver(
        configuration: .init(
            baseURL: baseURL,
            apiKey: "secret",
            defaultModel: "default-model",
            compatibility: compatibility
        ),
        transport: transport
    )
    let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["city": .object(["type": .string("string")])]),
    ])
    let request = LLMRequest(
        instructions: "Be concise",
        messages: [
            .user("Weather?"),
            .init(role: .assistant, content: [
                .text("Checking"),
                .toolCall(.init(
                    id: "call-1",
                    name: "weather",
                    arguments: .object(["city": .string("Paris")])
                )),
            ]),
            .toolResult(toolCallID: "call-1", content: "Sunny"),
        ],
        options: .init(
            temperature: 0.25,
            topP: 0.9,
            maxOutputTokens: 128,
            stopSequences: ["END"],
            seed: 42
        ),
        tools: [.init(name: "weather", description: "Get weather", inputSchema: schema)],
        toolChoice: .tool(named: "weather"),
        output: .jsonSchema(name: "forecast", schema: schema, strict: true),
        localMetadata: ["private": .string("not sent")]
    )

    _ = try await driver.generate(request)

    let urlRequest = try #require(await transport.recorder.last())
    #expect(urlRequest.url?.absoluteString == "https://example.test/v1/chat/completions")
    #expect(urlRequest.httpMethod == "POST")
    #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    #expect(urlRequest.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let body = try decodedBody(urlRequest)
    #expect(body["model"] == .string("default-model"))
    #expect(body["temperature"] == .number(0.25))
    #expect(body["top_p"] == .number(0.9))
    #expect(body["max_completion_tokens"] == .number(128))
    #expect(body["stop"] == .array([.string("END")]))
    #expect(body["seed"] == .number(42))
    #expect(body["private"] == nil)

    let messages = try #require(body["messages"]?.arrayValue)
    #expect(messages.count == 4)
    #expect(messages[0] == .object(["role": .string("system"), "content": .string("Be concise")]))
    #expect(messages[1]["role"] == .string("user"))
    #expect(messages[1]["content"] == .string("Weather?"))
    #expect(messages[2]["content"] == .string("Checking"))
    #expect(messages[2]["tool_calls"]?.arrayValue?.first?["id"] == .string("call-1"))
    #expect(messages[2]["tool_calls"]?.arrayValue?.first?["function"]?["name"] == .string("weather"))
    #expect(messages[2]["tool_calls"]?.arrayValue?.first?["function"]?["arguments"] == .string(#"{"city":"Paris"}"#))
    #expect(messages[3] == .object([
        "role": .string("tool"),
        "tool_call_id": .string("call-1"),
        "content": .string("Sunny"),
    ]))

    let tool = try #require(body["tools"]?.arrayValue?.first)
    #expect(tool["type"] == .string("function"))
    #expect(tool["function"]?["name"] == .string("weather"))
    #expect(tool["function"]?["description"] == .string("Get weather"))
    #expect(tool["function"]?["parameters"] == schema)
    #expect(body["tool_choice"]?["function"]?["name"] == .string("weather"))
    #expect(body["response_format"]?["type"] == .string("json_schema"))
    #expect(body["response_format"]?["json_schema"]?["name"] == .string("forecast"))
    #expect(body["response_format"]?["json_schema"]?["schema"] == schema)
    #expect(body["response_format"]?["json_schema"]?["strict"] == .boolean(true))
}

@Test("custom chat and models endpoint paths are used")
func customEndpoints() async throws {
    let generationTransport = MockTransport()
    let options = CompatibilityOptions(endpointPath: "/api/generate/")
    let driver = OpenAICompatibleDriver(
        configuration: .init(baseURL: baseURL, defaultModel: "model", compatibility: options),
        transport: generationTransport
    )
    _ = try await driver.generate(.text("hello"))
    #expect(await generationTransport.recorder.last()?.url?.absoluteString == "https://example.test/v1/api/generate")

    let modelTransport = MockTransport(body: #"{"data":[]}"#)
    let modelOptions = CompatibilityOptions(modelsEndpointPath: "/catalog/models/")
    let modelDriver = OpenAICompatibleDriver(
        configuration: .init(baseURL: baseURL, compatibility: modelOptions),
        transport: modelTransport
    )
    _ = try await modelDriver.listModels()
    let modelRequest = try #require(await modelTransport.recorder.last())
    #expect(modelRequest.url?.absoluteString == "https://example.test/v1/catalog/models")
    #expect(modelRequest.httpMethod == "GET")
}

@Test("capabilities reflect compatibility options")
func capabilitiesMapping() async throws {
    let options = CompatibilityOptions(
        supportsTools: false,
        supportsImages: false,
        supportsJSONObject: false,
        supportsJSONSchema: true
    )
    let driver = OpenAICompatibleDriver(configuration: .init(baseURL: baseURL, compatibility: options))
    let capabilities = try await driver.capabilities(for: nil)
    #expect(capabilities.supportsStreaming)
    #expect(!capabilities.supportsVision)
    #expect(!capabilities.supportsDocuments)
    #expect(!capabilities.supportsToolCalling)
    #expect(!capabilities.supportsJSONObjectOutput)
    #expect(capabilities.supportsJSONSchemaOutput)
    #expect(capabilities.supportsSeed)
}

@Test("unsupported request features fail before transport")
func capabilityValidation() async {
    let transport = MockTransport()
    let options = CompatibilityOptions(
        instructionStyle: .unsupported,
        supportsTools: false,
        supportsImages: false,
        supportsJSONObject: false,
        supportsJSONSchema: false
    )
    let driver = OpenAICompatibleDriver(
        configuration: .init(baseURL: baseURL, defaultModel: "model", compatibility: options),
        transport: transport
    )
    let schema: JSONValue = .object(["type": .string("object")])
    let requests: [(LLMRequest, LLMError)] = [
        (.text("hi", instructions: "system"), .unsupportedFeature("This endpoint does not support instructions")),
        (LLMRequest(messages: [.user("hi")], tools: [.init(name: "tool", inputSchema: schema)]), .unsupportedFeature("This endpoint does not support tools")),
        (LLMRequest(messages: [.user("hi")], output: .jsonObject), .unsupportedFeature("This endpoint does not support JSON object output")),
        (LLMRequest(messages: [.user("hi")], output: .jsonSchema(name: "x", schema: schema, strict: true)), .unsupportedFeature("This endpoint does not support JSON Schema output")),
        (LLMRequest(messages: [.init(role: .user, content: [.image(.init(data: Data([1]), mediaType: "image/png"))])]), .unsupportedFeature("This endpoint does not support images")),
        (LLMRequest(messages: [.init(role: .user, content: [.document(.init(data: Data([1]), mediaType: "text/plain"))])]), .unsupportedFeature("OpenAI-compatible chat completions do not support documents")),
    ]

    for (request, expected) in requests {
        let error = await caughtError { _ = try await driver.generate(request) }
        #expect(error == expected)
    }
    #expect(await transport.recorder.count() == 0)
}

@Test("normal response maps text, tool calls, usage, model, metadata, and finish reason")
func responseMapping() async throws {
    let body = #"{"id":"chat-1","model":"served-model","choices":[{"message":{"content":"Answer: ","tool_calls":[{"id":"call-9","type":"function","function":{"name":"lookup","arguments":"{\"key\":\"value\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":11,"completion_tokens":7},"system_fingerprint":"fp-1"}"#
    let driver = OpenAICompatibleDriver(
        configuration: .init(baseURL: baseURL, defaultModel: "model"),
        transport: MockTransport(body: body)
    )

    let response = try await driver.generate(.text("hello"))
    #expect(response.id == "chat-1")
    #expect(response.model == LLMModel("served-model"))
    #expect(response.text == "Answer: ")
    #expect(response.finishReason == .toolCalls)
    #expect(response.usage == .init(inputTokens: 11, outputTokens: 7))
    #expect(response.providerMetadata["system_fingerprint"] == .string("fp-1"))
    #expect(response.message.content.last == .toolCall(.init(
        id: "call-9",
        name: "lookup",
        arguments: .object(["key": .string("value")])
    )))
}

@Test("finish reasons are normalized")
func finishReasonMapping() async throws {
    let cases: [(String, LLMFinishReason)] = [
        ("stop", .completed),
        ("length", .maxOutputTokens),
        ("function_call", .toolCalls),
        ("content_filter", .contentFiltered),
        ("vendor_reason", .unknown("vendor_reason")),
    ]
    for (rawValue, expected) in cases {
        let body = #"{"choices":[{"message":{"content":"ok"},"finish_reason":"\#(rawValue)"}]}"#
        let driver = OpenAICompatibleDriver(
            configuration: .init(baseURL: baseURL, defaultModel: "model"),
            transport: MockTransport(body: body)
        )
        let response = try await driver.generate(.text("hello"))
        #expect(response.finishReason == expected)
    }
}

@Test("SSE handles split bytes, text, fragmented tool arguments, usage, and completion")
func streamingMapping() async throws {
    let chunks = [
        #"data: {"id":"stream-1","model":"stream-model","choices":[{"delta":{"content":"Hel"},"finish_reason":null}]}"#,
        "\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"lo\"},\"finish_reason\":null}]}\n\nda",
        #"ta: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"weather","arguments":"{\"city\":"}}]},"finish_reason":null}]}"#,
        "\n\n",
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Paris\"}"}}]},"finish_reason":"tool_calls"}]}"#,
        "\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}\n\ndata: [DONE]\n\n",
    ].map { Data($0.utf8) }
    let transport = MockTransport(streamChunks: chunks)
    let options = CompatibilityOptions(supportsStreamedUsage: true)
    let driver = OpenAICompatibleDriver(
        configuration: .init(baseURL: baseURL, defaultModel: "model", compatibility: options),
        transport: transport
    )

    var events: [LLMEvent] = []
    for try await event in driver.stream(.text("hello")) {
        events.append(event)
    }

    #expect(events.count == 8)
    #expect(events[0] == .started(id: "stream-1", model: "stream-model"))
    #expect(events[1] == .textDelta("Hel"))
    #expect(events[2] == .textDelta("lo"))
    #expect(events[3] == .toolCallStarted(id: "call-1", name: "weather"))
    #expect(events[4] == .toolCallArgumentsDelta(id: "call-1", jsonFragment: #"{"city":"#))
    #expect(events[5] == .toolCallArgumentsDelta(id: "call-1", jsonFragment: #""Paris"}"#))
    #expect(events[6] == .usage(.init(inputTokens: 3, outputTokens: 2)))
    let completed = try #require(events.last)
    guard case let .completed(response) = completed else {
        Issue.record("Expected completed event")
        return
    }
    #expect(response.text == "Hello")
    #expect(response.finishReason == .toolCalls)
    #expect(response.usage == .init(inputTokens: 3, outputTokens: 2))
    #expect(response.message.content.last == .toolCall(.init(
        id: "call-1",
        name: "weather",
        arguments: .object(["city": .string("Paris")])
    )))

    let request = try #require(await transport.recorder.last())
    let requestBody = try decodedBody(request)
    #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    #expect(requestBody["stream"] == .boolean(true))
    #expect(requestBody["stream_options"]?["include_usage"] == .boolean(true))
}

@Test("model listing maps catalog fields and metadata")
func modelMapping() async throws {
    let body = #"{"data":[{"id":"model-a","display_name":"Model A","owned_by":"vendor","created":1000,"context_window":8192},{"name":"model-b"}]}"#
    let driver = OpenAICompatibleDriver(
        configuration: .init(baseURL: baseURL),
        transport: MockTransport(body: body)
    )

    let models = try await driver.listModels()
    #expect(models.count == 2)
    #expect(models[0].model == LLMModel("model-a"))
    #expect(models[0].displayName == "Model A")
    #expect(models[0].ownedBy == "vendor")
    #expect(models[0].createdAt == Date(timeIntervalSince1970: 1000))
    #expect(models[0].metadata["context_window"] == .number(8192))
    #expect(models[1].model == LLMModel("model-b"))
}

@Test("HTTP status responses map to canonical errors")
func statusErrorMapping() async {
    let cases: [(Int, [String: String], LLMError)] = [
        (400, [:], .invalidRequest("bad request")),
        (401, [:], .authenticationFailed("bad request")),
        (403, [:], .permissionDenied("bad request")),
        (404, [:], .modelNotFound("bad request")),
        (408, [:], .networkError("bad request")),
        (429, ["Retry-After": "2.5"], .rateLimited(retryAfterSeconds: 2.5)),
        (503, [:], .serverError(statusCode: 503, message: "bad request")),
    ]
    for (status, headers, expected) in cases {
        let transport = MockTransport(
            statusCode: status,
            headers: headers,
            body: #"{"error":{"message":"bad request"}}"#
        )
        let driver = OpenAICompatibleDriver(
            configuration: .init(baseURL: baseURL, defaultModel: "model"),
            transport: transport
        )
        let error = await caughtError { _ = try await driver.generate(.text("hello")) }
        #expect(error == expected)
    }
}

@Test("model listing can be declared unsupported without sending a request")
func modelListingUnsupported() async {
    let transport = MockTransport()
    let options = CompatibilityOptions(supportsModelListing: false)
    let driver = OpenAICompatibleDriver(
        configuration: .init(baseURL: baseURL, compatibility: options),
        transport: transport
    )

    let error = await caughtError { _ = try await driver.listModels() }
    #expect(error == .unsupportedFeature("This endpoint does not support model listing"))
    #expect(await transport.recorder.count() == 0)
}
