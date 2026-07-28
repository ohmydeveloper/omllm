import Foundation
import LLMCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider adapter for Anthropic's Messages API.
public struct AnthropicDriver: LLMDriver {
    public let configuration: AnthropicConfiguration
    private let transport: any LLMTransport
    private let logger: (any LLMLogger)?

    public init(
        configuration: AnthropicConfiguration,
        transport: any LLMTransport = URLSessionTransport(),
        logger: (any LLMLogger)? = nil
    ) {
        self.configuration = configuration
        self.transport = transport
        self.logger = logger
    }

    public var providerID: LLMProviderID { .anthropic }

    public func capabilities(for model: LLMModel?) async throws -> LLMCapabilities {
        .init(
            supportsStreaming: true,
            supportsVision: true,
            supportsDocuments: true,
            supportsToolCalling: true,
            supportsJSONObjectOutput: false,
            supportsJSONSchemaOutput: false,
            supportsSeed: false
        )
    }

    public func listModels() async throws -> [LLMModelInfo] {
        do {
            var models: [LLMModelInfo] = []
            var afterID: String?
            var seenPageTokens = Set<String>()
            repeat {
                let request = try makeRequest(path: "v1/models", method: "GET", afterID: afterID)
                logRequest(operation: "list_models", model: nil, streaming: false)
                let result = try await transport.send(request)
                try validate(result)
                let value = try decodeJSON(result.data)
                guard let data = value["data"]?.arrayValue else {
                    throw LLMError.invalidResponse("Anthropic models response did not contain a data array")
                }
                models += try data.map(mapModel)
                let hasMore = value["has_more"]?.boolValue ?? false
                guard hasMore else { afterID = nil; continue }
                guard let lastID = value["last_id"]?.stringValue, !lastID.isEmpty else {
                    throw LLMError.invalidResponse("Anthropic models response indicated another page without last_id")
                }
                guard seenPageTokens.insert(lastID).inserted else {
                    throw LLMError.invalidResponse("Anthropic models pagination repeated last_id")
                }
                afterID = lastID
            } while afterID != nil
            logCompletion(operation: "list_models")
            return models
        } catch {
            throw report(error, operation: "list_models")
        }
    }

    public func generate(_ request: LLMRequest) async throws -> LLMResponse {
        do {
            let draft = try AnthropicRequestMapper().map(
                request,
                defaultModel: configuration.defaultModel,
                defaultMaxOutputTokens: configuration.defaultMaxOutputTokens
            )
            let urlRequest = try makeRequest(path: "v1/messages", method: "POST", body: draft.body)
            logRequest(operation: "generate", model: draft.model, streaming: false)
            let result = try await transport.send(urlRequest)
            try validate(result)
            var response = try AnthropicResponseMapper().map(decodeJSON(result.data))
            if let requestID = header("request-id", in: result.headers)
                ?? header("x-request-id", in: result.headers) {
                response.providerMetadata.additionalValues["request_id"] = .string(requestID)
            }
            logCompletion(operation: "generate")
            return response
        } catch {
            throw report(error, operation: "generate")
        }
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let draft = try AnthropicRequestMapper().map(
                        request,
                        defaultModel: configuration.defaultModel,
                        defaultMaxOutputTokens: configuration.defaultMaxOutputTokens
                    )
                    guard case let .object(originalBody) = draft.body else {
                        throw LLMError.invalidRequest("Anthropic request body was invalid")
                    }
                    var body = originalBody
                    body["stream"] = .boolean(true)
                    let urlRequest = try makeRequest(
                        path: "v1/messages",
                        method: "POST",
                        body: .object(body),
                        acceptsSSE: true
                    )
                    logRequest(operation: "stream", model: draft.model, streaming: true)
                    try await consumeStream(transport.stream(urlRequest), continuation: continuation)
                    logCompletion(operation: "stream")
                } catch {
                    continuation.finish(throwing: report(error, operation: "stream"))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func consumeStream(
        _ bytes: AsyncThrowingStream<Data, Error>,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        var parser = SSEParser()
        var state = AnthropicStreamState()
        for try await chunk in bytes {
            try Task.checkCancellation()
            for event in parser.append(chunk) {
                try process(event, state: &state, continuation: continuation)
            }
        }
        for event in parser.finish() {
            try process(event, state: &state, continuation: continuation)
        }
        guard state.completed else {
            throw LLMError.invalidResponse("Anthropic stream ended without message_stop")
        }
        continuation.finish()
    }

    private func process(
        _ event: SSEEvent,
        state: inout AnthropicStreamState,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) throws {
        guard let data = event.data.data(using: .utf8) else {
            throw LLMError.invalidResponse("Anthropic stream event was not UTF-8")
        }
        let value = try decodeJSON(data)
        let type = value["type"]?.stringValue ?? event.event
        switch type {
        case "message_start":
            guard !state.started else { return }
            let message = value["message"]
            state.started = true
            state.id = message?["id"]?.stringValue
            state.model = message?["model"]?.stringValue
            state.inputTokens = message?["usage"]?["input_tokens"]?.numberValue.map(Int.init)
            continuation.yield(.started(
                id: state.id,
                model: state.model.map { LLMModel($0) }
            ))
        case "content_block_start":
            guard let index = value["index"]?.numberValue.map(Int.init),
                  let block = value["content_block"] else { return }
            switch block["type"]?.stringValue {
            case "text":
                let text = block["text"]?.stringValue ?? ""
                state.blocks[index] = .text(text)
                if !text.isEmpty { continuation.yield(.textDelta(text)) }
            case "tool_use":
                guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else {
                    throw LLMError.invalidResponse("Anthropic streamed an incomplete tool_use block")
                }
                state.blocks[index] = .tool(id: id, name: name, arguments: "")
                continuation.yield(.toolCallStarted(id: id, name: name))
            default:
                state.blocks[index] = .ignored
            }
        case "content_block_delta":
            guard let index = value["index"]?.numberValue.map(Int.init), let delta = value["delta"] else {
                return
            }
            switch delta["type"]?.stringValue {
            case "text_delta":
                guard let text = delta["text"]?.stringValue else { return }
                if case let .text(existing) = state.blocks[index] {
                    state.blocks[index] = .text(existing + text)
                } else {
                    state.blocks[index] = .text(text)
                }
                continuation.yield(.textDelta(text))
            case "input_json_delta":
                guard let fragment = delta["partial_json"]?.stringValue,
                      case let .tool(id, name, arguments) = state.blocks[index] else {
                    throw LLMError.invalidResponse("Anthropic streamed tool input before tool_use")
                }
                state.blocks[index] = .tool(id: id, name: name, arguments: arguments + fragment)
                continuation.yield(.toolCallArgumentsDelta(id: id, jsonFragment: fragment))
            default: return
            }
        case "message_delta":
            state.stopReason = value["delta"]?["stop_reason"]?.stringValue ?? state.stopReason
            state.stopSequence = value["delta"]?["stop_sequence"]?.stringValue ?? state.stopSequence
            if let output = value["usage"]?["output_tokens"]?.numberValue.map(Int.init) {
                state.outputTokens = output
                continuation.yield(.usage(.init(
                    inputTokens: state.inputTokens,
                    outputTokens: state.outputTokens
                )))
            }
        case "message_stop":
            guard state.started else {
                throw LLMError.invalidResponse("Anthropic stream stopped before message_start")
            }
            let response = try state.response()
            if state.outputTokens == nil, let usage = response.usage { continuation.yield(.usage(usage)) }
            continuation.yield(.completed(response))
            state.completed = true
        case "error":
            throw apiError(value, statusCode: nil, headers: [:])
        case "ping", "content_block_stop":
            return
        default:
            return
        }
    }

    private func makeRequest(
        path: String,
        method: String,
        body: JSONValue? = nil,
        acceptsSSE: Bool = false,
        afterID: String? = nil
    ) throws -> URLRequest {
        guard configuration.timeout > 0 else {
            throw LLMError.invalidRequest("Anthropic timeout must be greater than zero")
        }
        guard configuration.defaultMaxOutputTokens > 0 else {
            throw LLMError.invalidRequest("Anthropic defaultMaxOutputTokens must be greater than zero")
        }
        var url = configuration.baseURL.appendingPathComponent(path)
        guard let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else {
            throw LLMError.invalidRequest("Anthropic base URL must use HTTP or HTTPS")
        }
        if let afterID {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw LLMError.invalidRequest("Anthropic models URL was invalid")
            }
            var items = components.queryItems ?? []
            items.append(.init(name: "after_id", value: afterID))
            components.queryItems = items
            guard let paginatedURL = components.url else {
                throw LLMError.invalidRequest("Anthropic models pagination URL was invalid")
            }
            url = paginatedURL
        }
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = method
        for (name, value) in configuration.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(acceptsSSE ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if !configuration.betaFeatures.isEmpty {
            request.setValue(configuration.betaFeatures.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    private func mapModel(_ value: JSONValue) throws -> LLMModelInfo {
        guard let id = value["id"]?.stringValue else {
            throw LLMError.invalidResponse("Anthropic model entry did not contain an id")
        }
        let createdAt = value["created_at"]?.stringValue.flatMap(Self.parseDate)
        var metadata = value.objectValue ?? [:]
        for key in ["id", "display_name", "created_at"] { metadata.removeValue(forKey: key) }
        return .init(
            model: .init(id),
            displayName: value["display_name"]?.stringValue,
            ownedBy: "anthropic",
            createdAt: createdAt,
            metadata: .init(metadata)
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private func validate(_ response: LLMTransportResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw apiErrorData(response.data, statusCode: response.statusCode, headers: response.headers)
        }
    }

    private func decodeJSON(_ data: Data) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw LLMError.invalidResponse("Anthropic returned invalid JSON: \(error.localizedDescription)")
        }
    }

    private func report(_ error: Error, operation: String) -> LLMError {
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

    private func apiError(
        _ value: JSONValue?,
        statusCode: Int?,
        headers: [String: String]
    ) -> LLMError {
        let error = value?["error"] ?? value
        let message = error?["message"]?.stringValue ?? "Anthropic API request failed"
        let type = error?["type"]?.stringValue
        switch statusCode {
        case 400:
            if message.localizedCaseInsensitiveContains("context") { return .contextLengthExceeded(message) }
            return .invalidRequest(message)
        case 401: return .authenticationFailed(message)
        case 403: return .permissionDenied(message)
        case 404: return .modelNotFound(message)
        case 408: return .networkError(message)
        case 429: return .rateLimited(retryAfterSeconds: retryAfter(headers))
        case let status? where status >= 500: return .serverError(statusCode: status, message: message)
        default:
            if type == "authentication_error" { return .authenticationFailed(message) }
            if type == "permission_error" { return .permissionDenied(message) }
            if type == "not_found_error" { return .modelNotFound(message) }
            if type == "rate_limit_error" { return .rateLimited(retryAfterSeconds: retryAfter(headers)) }
            if type == "invalid_request_error" { return .invalidRequest(message) }
            return .serverError(statusCode: statusCode, message: message)
        }
    }

    private func retryAfter(_ headers: [String: String]) -> Double? {
        headers.first { $0.key.caseInsensitiveCompare("retry-after") == .orderedSame }
            .flatMap { Double($0.value) }
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func logRequest(operation: String, model: String?, streaming: Bool) {
        var metadata: [String: JSONValue] = [
            "operation": .string(operation),
            "streaming": .boolean(streaming),
        ]
        if let model { metadata["model"] = .string(model) }
        logger?.logRequest(provider: providerID, metadata: metadata)
    }

    private func logCompletion(operation: String) {
        logger?.logCompletion(provider: providerID, metadata: ["operation": .string(operation)])
    }
}

private enum AnthropicStreamBlock: Sendable {
    case text(String)
    case tool(id: String, name: String, arguments: String)
    case ignored
}

private struct AnthropicStreamState: Sendable {
    var started = false
    var completed = false
    var id: String?
    var model: String?
    var stopReason: String?
    var stopSequence: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var blocks: [Int: AnthropicStreamBlock] = [:]

    func response() throws -> LLMResponse {
        var content: [LLMContent] = []
        for index in blocks.keys.sorted() {
            guard let block = blocks[index] else { continue }
            switch block {
            case let .text(text):
                content.append(.text(text))
            case let .tool(id, name, arguments):
                let data = Data((arguments.isEmpty ? "{}" : arguments).utf8)
                let input: JSONValue
                do {
                    input = try JSONDecoder().decode(JSONValue.self, from: data)
                } catch {
                    throw LLMError.invalidResponse("Anthropic streamed invalid tool input JSON")
                }
                content.append(.toolCall(.init(id: id, name: name, arguments: input)))
            case .ignored:
                continue
            }
        }
        var metadata: [String: JSONValue] = [:]
        if let stopSequence { metadata["stop_sequence"] = .string(stopSequence) }
        let usage: TokenUsage? = inputTokens != nil || outputTokens != nil
            ? .init(inputTokens: inputTokens, outputTokens: outputTokens)
            : nil
        return .init(
            id: id,
            model: model.map { LLMModel($0) },
            message: .init(role: .assistant, content: content),
            finishReason: AnthropicResponseMapper().finishReason(stopReason),
            usage: usage,
            providerMetadata: .init(metadata)
        )
    }
}
