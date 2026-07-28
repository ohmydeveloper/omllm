import Foundation
import LLMCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider adapter for configurable OpenAI-compatible servers.
public struct OpenAICompatibleDriver: LLMDriver {
    public let configuration: OpenAICompatibleConfiguration
    let transport: any LLMTransport
    let logger: (any LLMLogger)?

    public init(
        configuration: OpenAICompatibleConfiguration,
        transport: any LLMTransport = URLSessionTransport(),
        logger: (any LLMLogger)? = nil
    ) {
        self.configuration = configuration
        self.transport = transport
        self.logger = logger
    }

    public var providerID: LLMProviderID { configuration.providerID }

    public func capabilities(for model: LLMModel?) async throws -> LLMCapabilities {
        if configuration.dialect == .responses {
            return .init(
                supportsStreaming: true,
                supportsVision: true,
                supportsDocuments: true,
                supportsToolCalling: true,
                supportsJSONObjectOutput: true,
                supportsJSONSchemaOutput: true,
                supportsSeed: false
            )
        }
        return .init(
            supportsStreaming: true,
            supportsVision: configuration.compatibility.supportsImages,
            supportsDocuments: false,
            supportsToolCalling: configuration.compatibility.supportsTools,
            supportsJSONObjectOutput: configuration.compatibility.supportsJSONObject,
            supportsJSONSchemaOutput: configuration.compatibility.supportsJSONSchema,
            supportsSeed: true
        )
    }

    public func listModels() async throws -> [LLMModelInfo] {
        do {
            guard configuration.compatibility.supportsModelListing else {
                throw LLMError.unsupportedFeature("This endpoint does not support model listing")
            }
            let request = try makeRequest(
                path: configuration.compatibility.modelsEndpointPath,
                method: "GET"
            )
            logRequest(operation: "list_models", model: nil, streaming: false)
            let response = try await transport.send(request)
            try validate(response)
            let root = try decodeJSON(response.data)
            let values = root["data"]?.arrayValue ?? root["models"]?.arrayValue ?? root.arrayValue
            guard let values else {
                throw LLMError.invalidResponse("Model response did not contain an array")
            }
            let models = try values.map(mapModel)
            logCompletion(operation: "list_models")
            return models
        } catch {
            throw report(error, operation: "list_models")
        }
    }

    public func generate(_ request: LLMRequest) async throws -> LLMResponse {
        do {
            if configuration.dialect == .responses {
                return try await generateResponses(request)
            }
            try validate(request)
            let (body, model) = try requestBody(request, streaming: false)
            let urlRequest = try makeRequest(
                path: generationEndpointPath,
                method: "POST",
                body: body
            )
            logRequest(operation: "generate", model: model, streaming: false)
            let response = try await transport.send(urlRequest)
            try validate(response)
            var mapped = try mapResponse(decodeJSON(response.data))
            if let requestID = header("x-request-id", in: response.headers) {
                mapped.providerMetadata.additionalValues["request_id"] = .string(requestID)
            }
            logCompletion(operation: "generate")
            return mapped
        } catch {
            throw report(error, operation: "generate")
        }
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if configuration.dialect == .responses {
                        try await streamResponses(request, continuation: continuation)
                        return
                    }
                    try validate(request)
                    let (body, model) = try requestBody(request, streaming: true)
                    let urlRequest = try makeRequest(
                        path: generationEndpointPath,
                        method: "POST",
                        body: body,
                        acceptsSSE: true
                    )
                    logRequest(operation: "stream", model: model, streaming: true)
                    try await consumeStream(transport.stream(urlRequest), continuation: continuation)
                    logCompletion(operation: "stream")
                } catch {
                    continuation.finish(throwing: report(error, operation: "stream"))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func validate(_ request: LLMRequest) throws {
        guard request.model != nil || configuration.defaultModel != nil else {
            throw LLMError.invalidRequest("A model is required")
        }
        if !request.tools.isEmpty && !configuration.compatibility.supportsTools {
            throw LLMError.unsupportedFeature("This endpoint does not support tools")
        }
        if case .jsonSchema = request.output,
           !configuration.compatibility.supportsJSONSchema {
            throw LLMError.unsupportedFeature("This endpoint does not support JSON Schema output")
        }
        if case .jsonObject = request.output,
           !configuration.compatibility.supportsJSONObject {
            throw LLMError.unsupportedFeature("This endpoint does not support JSON object output")
        }
        if request.instructions != nil,
           configuration.compatibility.instructionStyle == .unsupported {
            throw LLMError.unsupportedFeature("This endpoint does not support instructions")
        }
        for message in request.messages {
            for content in message.content {
                if case .image = content, !configuration.compatibility.supportsImages {
                    throw LLMError.unsupportedFeature("This endpoint does not support images")
                }
                if case .document = content {
                    throw LLMError.unsupportedFeature("OpenAI-compatible chat completions do not support documents")
                }
                if case .toolCall = content, !configuration.compatibility.supportsTools {
                    throw LLMError.unsupportedFeature("This endpoint does not support tools")
                }
                if case .toolResult = content, !configuration.compatibility.supportsTools {
                    throw LLMError.unsupportedFeature("This endpoint does not support tools")
                }
            }
        }
    }

    var generationEndpointPath: String {
        configuration.generationEndpointPath
            ?? configuration.compatibility.endpointPath
            ?? (configuration.dialect == .responses ? "responses" : "chat/completions")
    }

    private func requestBody(_ request: LLMRequest, streaming: Bool) throws -> (JSONValue, String) {
        let model = request.model?.id ?? configuration.defaultModel
        guard let model else { throw LLMError.invalidRequest("A model is required") }
        var messages: [JSONValue] = []
        if let instructions = request.instructions {
            let role = configuration.compatibility.instructionStyle.rawValue
            messages.append(.object(["role": .string(role), "content": .string(instructions)]))
        }
        for message in request.messages {
            messages.append(contentsOf: try mapMessage(message))
        }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages),
        ]
        if streaming {
            body["stream"] = .boolean(true)
            if configuration.compatibility.supportsStreamedUsage {
                body["stream_options"] = .object(["include_usage": .boolean(true)])
            }
        }
        if let value = request.options.temperature { body["temperature"] = .number(value) }
        if let value = request.options.topP { body["top_p"] = .number(value) }
        if let value = request.options.maxOutputTokens {
            body[tokenFieldName] = .number(Double(value))
        }
        if !request.options.stopSequences.isEmpty {
            body["stop"] = .array(request.options.stopSequences.map(JSONValue.string))
        }
        if let value = request.options.seed { body["seed"] = .number(Double(value)) }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                var function: [String: JSONValue] = [
                    "name": .string(tool.name),
                    "parameters": tool.inputSchema,
                ]
                if let description = tool.description { function["description"] = .string(description) }
                return .object(["type": .string("function"), "function": .object(function)])
            })
        }
        if let choice = request.toolChoice { body["tool_choice"] = mapToolChoice(choice) }
        switch request.output {
        case .text:
            break
        case .jsonObject:
            body["response_format"] = .object(["type": .string("json_object")])
        case let .jsonSchema(name, schema, strict):
            body["response_format"] = .object([
                "type": .string("json_schema"),
                "json_schema": .object([
                    "name": .string(name),
                    "schema": schema,
                    "strict": .boolean(strict),
                ]),
            ])
        }
        return (.object(body), model)
    }

    private var tokenFieldName: String {
        switch configuration.compatibility.maxTokenField {
        case .maxTokens: "max_tokens"
        case .maxCompletionTokens: "max_completion_tokens"
        case .maxOutputTokens: "max_output_tokens"
        }
    }

    private func mapMessage(_ message: LLMMessage) throws -> [JSONValue] {
        if message.role == .tool {
            return try message.content.map { content in
                guard case let .toolResult(result) = content else {
                    throw LLMError.invalidRequest("Tool messages may only contain tool results")
                }
                return .object([
                    "role": .string("tool"),
                    "tool_call_id": .string(result.toolCallID),
                    "content": .string(result.content),
                ])
            }
        }
        var textAndImages: [JSONValue] = []
        var toolCalls: [JSONValue] = []
        for content in message.content {
            switch content {
            case let .text(text):
                textAndImages.append(.object(["type": .string("text"), "text": .string(text)]))
            case let .image(image):
                textAndImages.append(.object([
                    "type": .string("image_url"),
                    "image_url": .object(["url": .string(try imageURL(image))]),
                ]))
            case let .toolCall(call):
                let arguments = try encodeJSONString(call.arguments)
                toolCalls.append(.object([
                    "id": .string(call.id),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(call.name),
                        "arguments": .string(arguments),
                    ]),
                ]))
            case .document:
                throw LLMError.unsupportedFeature("OpenAI-compatible chat completions do not support documents")
            case .toolResult:
                throw LLMError.invalidRequest("Tool results must use the tool role")
            }
        }
        var mapped: [String: JSONValue] = ["role": .string(message.role.rawValue)]
        if textAndImages.count == 1,
           textAndImages[0]["type"]?.stringValue == "text",
           let text = textAndImages[0]["text"]?.stringValue {
            mapped["content"] = .string(text)
        } else if !textAndImages.isEmpty {
            mapped["content"] = .array(textAndImages)
        } else {
            mapped["content"] = .null
        }
        if !toolCalls.isEmpty { mapped["tool_calls"] = .array(toolCalls) }
        return [.object(mapped)]
    }

    private func imageURL(_ image: LLMImage) throws -> String {
        if let url = image.url { return url.absoluteString }
        if let data = image.data, let mediaType = image.mediaType, !mediaType.isEmpty {
            return "data:\(mediaType);base64,\(data.base64EncodedString())"
        }
        throw LLMError.invalidRequest("An image must contain a URL or data with a media type")
    }

    private func mapToolChoice(_ choice: LLMToolChoice) -> JSONValue {
        switch choice {
        case .auto: .string("auto")
        case .none: .string("none")
        case .required: .string("required")
        case let .tool(name):
            .object([
                "type": .string("function"),
                "function": .object(["name": .string(name)]),
            ])
        }
    }

    private func mapResponse(_ root: JSONValue) throws -> LLMResponse {
        if root["error"] != nil { throw apiError(root, statusCode: nil, headers: [:]) }
        guard let choice = root["choices"]?.arrayValue?.first,
              let message = choice["message"] else {
            throw LLMError.invalidResponse("Chat completion did not contain a choice message")
        }
        var content: [LLMContent] = []
        if let text = responseText(message["content"]) { content.append(.text(text)) }
        content.append(contentsOf: try mapToolCalls(message["tool_calls"]))
        return LLMResponse(
            id: root["id"]?.stringValue,
            model: root["model"]?.stringValue.map { LLMModel($0) },
            message: .init(role: .assistant, content: content),
            finishReason: finishReason(choice["finish_reason"]?.stringValue),
            usage: mapUsage(root["usage"]),
            providerMetadata: metadata(from: root, excluding: ["id", "model", "choices", "usage"])
        )
    }

    private func responseText(_ value: JSONValue?) -> String? {
        if let text = value?.stringValue { return text }
        return value?.arrayValue?.compactMap { item in
            guard item["type"]?.stringValue == "text" else { return nil }
            return item["text"]?.stringValue
        }.joined()
    }

    private func mapToolCalls(_ value: JSONValue?) throws -> [LLMContent] {
        try (value?.arrayValue ?? []).map { call in
            guard let id = call["id"]?.stringValue,
                  let name = call["function"]?["name"]?.stringValue,
                  let arguments = call["function"]?["arguments"]?.stringValue else {
                throw LLMError.invalidResponse("Tool call was missing its id, name, or arguments")
            }
            return .toolCall(.init(id: id, name: name, arguments: try decodeJSONString(arguments)))
        }
    }

    private func mapUsage(_ value: JSONValue?) -> TokenUsage? {
        guard value != nil else { return nil }
        let input = integer(value?["prompt_tokens"] ?? value?["input_tokens"])
        let output = integer(value?["completion_tokens"] ?? value?["output_tokens"])
        guard input != nil || output != nil else { return nil }
        return .init(inputTokens: input, outputTokens: output)
    }

    private func integer(_ value: JSONValue?) -> Int? {
        value?.numberValue.map(Int.init)
    }

    private func finishReason(_ value: String?) -> LLMFinishReason {
        switch value {
        case "stop": .completed
        case "length": .maxOutputTokens
        case "tool_calls", "function_call": .toolCalls
        case "content_filter": .contentFiltered
        case nil: .unknown("missing")
        case let value?: .unknown(value)
        }
    }

    private func consumeStream(
        _ bytes: AsyncThrowingStream<Data, Error>,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        var parser = SSEParser()
        var state = CompatibleStreamState()
        for try await chunk in bytes {
            try Task.checkCancellation()
            for event in parser.append(chunk) {
                if try process(event, state: &state, continuation: continuation) { return }
            }
        }
        for event in parser.finish() {
            if try process(event, state: &state, continuation: continuation) { return }
        }
        guard state.finishReason != nil else {
            throw LLMError.invalidResponse("Chat completion stream ended without [DONE] or a finish reason")
        }
        try completeStream(state: &state, continuation: continuation)
    }

    private func process(
        _ event: SSEEvent,
        state: inout CompatibleStreamState,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) throws -> Bool {
        if event.isDone {
            try completeStream(state: &state, continuation: continuation)
            return true
        }
        guard let data = event.data.data(using: .utf8) else {
            throw LLMError.invalidResponse("Stream event was not UTF-8")
        }
        let root = try decodeJSON(data)
        if root["error"] != nil { throw apiError(root, statusCode: nil, headers: [:]) }
        if !state.started {
            state.started = true
            state.id = root["id"]?.stringValue
            state.model = root["model"]?.stringValue
            continuation.yield(.started(id: state.id, model: state.model.map { LLMModel($0) }))
        }
        if let usage = mapUsage(root["usage"]) {
            state.usage = usage
            continuation.yield(.usage(usage))
        }
        guard let choice = root["choices"]?.arrayValue?.first else { return false }
        let delta = choice["delta"]
        if let text = responseText(delta?["content"]), !text.isEmpty {
            state.text += text
            continuation.yield(.textDelta(text))
        }
        for call in delta?["tool_calls"]?.arrayValue ?? [] {
            let index = integer(call["index"]) ?? 0
            var pending = state.toolCalls[index] ?? .init()
            if let id = call["id"]?.stringValue { pending.id += id }
            if let name = call["function"]?["name"]?.stringValue { pending.name += name }
            let argument = call["function"]?["arguments"]?.stringValue ?? ""
            pending.arguments += argument
            pending.unemittedArguments += argument
            if !pending.started, !pending.id.isEmpty, !pending.name.isEmpty {
                pending.started = true
                continuation.yield(.toolCallStarted(id: pending.id, name: pending.name))
            }
            if pending.started, !pending.unemittedArguments.isEmpty {
                continuation.yield(.toolCallArgumentsDelta(
                    id: pending.id,
                    jsonFragment: pending.unemittedArguments
                ))
                pending.unemittedArguments = ""
            }
            state.toolCalls[index] = pending
        }
        if let reason = choice["finish_reason"]?.stringValue { state.finishReason = reason }
        return false
    }

    private func completeStream(
        state: inout CompatibleStreamState,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) throws {
        guard !state.completed else { return }
        var content: [LLMContent] = []
        if !state.text.isEmpty { content.append(.text(state.text)) }
        for (_, call) in state.toolCalls.sorted(by: { $0.key < $1.key }) {
            guard !call.id.isEmpty, !call.name.isEmpty else {
                throw LLMError.invalidResponse("Streamed tool call was missing its id or name")
            }
            content.append(.toolCall(.init(
                id: call.id,
                name: call.name,
                arguments: try decodeJSONString(call.arguments)
            )))
        }
        let response = LLMResponse(
            id: state.id,
            model: state.model.map { LLMModel($0) },
            message: .init(role: .assistant, content: content),
            finishReason: finishReason(state.finishReason),
            usage: state.usage
        )
        state.completed = true
        continuation.yield(.completed(response))
        continuation.finish()
    }

    func makeRequest(
        path: String,
        method: String,
        body: JSONValue? = nil,
        acceptsSSE: Bool = false
    ) throws -> URLRequest {
        guard configuration.timeout > 0 else {
            throw LLMError.invalidRequest("Timeout must be greater than zero")
        }
        guard let scheme = configuration.baseURL.scheme,
              ["http", "https"].contains(scheme.lowercased()) else {
            throw LLMError.invalidRequest("Base URL must use HTTP or HTTPS")
        }
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.invalidRequest("Endpoint path must not be empty")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        let url = components.reduce(configuration.baseURL) { url, component in
            url.appendingPathComponent(String(component))
        }
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = method
        request.setValue(acceptsSSE ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        switch configuration.compatibility.authenticationStyle {
        case .bearer:
            if let apiKey = configuration.apiKey {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        case let .apiKey(header):
            guard !header.isEmpty else { throw LLMError.invalidRequest("API key header must not be empty") }
            if let apiKey = configuration.apiKey { request.setValue(apiKey, forHTTPHeaderField: header) }
        case .none:
            break
        }
        if let organization = configuration.organization {
            request.setValue(organization, forHTTPHeaderField: "OpenAI-Organization")
        }
        if let project = configuration.project {
            request.setValue(project, forHTTPHeaderField: "OpenAI-Project")
        }
        for (name, value) in configuration.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    func validate(_ response: LLMTransportResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw apiErrorData(response.data, statusCode: response.statusCode, headers: response.headers)
        }
    }

    func decodeJSON(_ data: Data) throws -> JSONValue {
        do { return try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw LLMError.invalidResponse("Endpoint returned invalid JSON: \(error.localizedDescription)") }
    }

    private func decodeJSONString(_ string: String) throws -> JSONValue {
        guard let data = string.data(using: .utf8) else {
            throw LLMError.invalidResponse("Tool arguments were not UTF-8")
        }
        return try decodeJSON(data)
    }

    private func encodeJSONString(_ value: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw LLMError.invalidRequest("Tool arguments could not be encoded as UTF-8")
        }
        return string
    }

    private func mapModel(_ value: JSONValue) throws -> LLMModelInfo {
        let id = value["id"]?.stringValue
            ?? value["name"]?.stringValue
            ?? value["model"]?.stringValue
        guard let id else { throw LLMError.invalidResponse("Model entry did not contain an id") }
        return LLMModelInfo(
            model: .init(id),
            displayName: value["display_name"]?.stringValue,
            ownedBy: value["owned_by"]?.stringValue,
            createdAt: value["created"]?.numberValue.map(Date.init(timeIntervalSince1970:)),
            metadata: metadata(
                from: value,
                excluding: ["id", "name", "model", "display_name", "owned_by", "created"]
            )
        )
    }

    private func metadata(from value: JSONValue, excluding keys: Set<String>) -> ProviderMetadata {
        guard let object = value.objectValue else { return .init() }
        return .init(object.filter { !keys.contains($0.key) })
    }

    func report(_ error: Error, operation: String) -> LLMError {
        let normalized: LLMError
        if let error = error as? LLMError {
            normalized = error
        } else if case let LLMTransportError.httpStatus(response) = error {
            normalized = apiErrorData(response.data, statusCode: response.statusCode, headers: response.headers)
        } else if error is CancellationError {
            normalized = .cancelled
        } else {
            normalized = .networkError(String(describing: error))
        }
        logger?.logFailure(
            provider: providerID,
            error: normalized,
            metadata: ["operation": .string(operation)]
        )
        return normalized
    }

    private func apiErrorData(
        _ data: Data,
        statusCode: Int?,
        headers: [String: String]
    ) -> LLMError {
        apiError(try? JSONDecoder().decode(JSONValue.self, from: data), statusCode: statusCode, headers: headers)
    }

    func apiError(
        _ value: JSONValue?,
        statusCode: Int?,
        headers: [String: String]
    ) -> LLMError {
        let error = value?["error"] ?? value
        let message = error?["message"]?.stringValue
            ?? error?["detail"]?.stringValue
            ?? "OpenAI-compatible API request failed"
        let code = error?["code"]?.stringValue
        if code == "context_length_exceeded" || message.lowercased().contains("context length") {
            return .contextLengthExceeded(message)
        }
        switch statusCode {
        case 400, 422: return .invalidRequest(message)
        case 401: return .authenticationFailed(message)
        case 403: return .permissionDenied(message)
        case 404: return .modelNotFound(message)
        case 408: return .networkError(message)
        case 429: return .rateLimited(retryAfterSeconds: retryAfter(headers))
        case let status? where status >= 500: return .serverError(statusCode: status, message: message)
        default: return .serverError(statusCode: statusCode, message: message)
        }
    }

    private func retryAfter(_ headers: [String: String]) -> Double? {
        headers.first { $0.key.caseInsensitiveCompare("retry-after") == .orderedSame }
            .flatMap { Double($0.value) }
    }

    func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func logRequest(operation: String, model: String?, streaming: Bool) {
        var metadata: [String: JSONValue] = [
            "operation": .string(operation),
            "streaming": .boolean(streaming),
        ]
        if let model { metadata["model"] = .string(model) }
        logger?.logRequest(provider: providerID, metadata: metadata)
    }

    func logCompletion(operation: String) {
        logger?.logCompletion(provider: providerID, metadata: ["operation": .string(operation)])
    }
}

private struct CompatibleStreamToolCall: Sendable {
    var id = ""
    var name = ""
    var arguments = ""
    var unemittedArguments = ""
    var started = false
}

private struct CompatibleStreamState: Sendable {
    var started = false
    var completed = false
    var id: String?
    var model: String?
    var text = ""
    var toolCalls: [Int: CompatibleStreamToolCall] = [:]
    var usage: TokenUsage?
    var finishReason: String?
}
