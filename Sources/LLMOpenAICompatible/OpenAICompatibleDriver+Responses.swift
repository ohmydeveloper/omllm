import Foundation
import LLMCore

extension OpenAICompatibleDriver {
    func generateResponses(_ request: LLMRequest) async throws -> LLMResponse {
        let draft = try OpenAIResponsesRequestMapper().map(request, defaultModel: configuration.defaultModel)
        let urlRequest = try makeRequest(path: generationEndpointPath, method: "POST", body: draft.body)
        logRequest(operation: "generate", model: draft.model, streaming: false)
        let result = try await transport.send(urlRequest)
        try validate(result)
        var response = try OpenAIResponsesResponseMapper().map(decodeJSON(result.data))
        if let requestID = header("x-request-id", in: result.headers) { response.providerMetadata.additionalValues["request_id"] = .string(requestID) }
        logCompletion(operation: "generate")
        return response
    }

    func streamResponses(_ request: LLMRequest, continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws {
        let draft = try OpenAIResponsesRequestMapper().map(request, defaultModel: configuration.defaultModel)
        guard case let .object(originalBody) = draft.body else { throw LLMError.invalidRequest("OpenAI request body was invalid") }
        var body = originalBody
        body["stream"] = .boolean(true)
        let urlRequest = try makeRequest(path: generationEndpointPath, method: "POST", body: .object(body), acceptsSSE: true)
        logRequest(operation: "stream", model: draft.model, streaming: true)
        var parser = SSEParser()
        var state = OpenAICompatibleResponsesStreamState()
        for try await chunk in transport.stream(urlRequest) {
            try Task.checkCancellation()
            for event in parser.append(chunk) {
                if event.isDone {
                    guard state.completed else {
                        throw LLMError.invalidResponse("OpenAI stream ended before a terminal response event")
                    }
                    continue
                }
                try processResponsesEvent(event, state: &state, continuation: continuation)
            }
        }
        for event in parser.finish() {
            if event.isDone {
                guard state.completed else {
                    throw LLMError.invalidResponse("OpenAI stream ended before a terminal response event")
                }
                continue
            }
            try processResponsesEvent(event, state: &state, continuation: continuation)
        }
        guard state.completed else { throw LLMError.invalidResponse("OpenAI stream ended without a terminal response event") }
        continuation.finish()
        logCompletion(operation: "stream")
    }

    private func processResponsesEvent(_ event: SSEEvent, state: inout OpenAICompatibleResponsesStreamState, continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) throws {
        guard let data = event.data.data(using: .utf8) else { throw LLMError.invalidResponse("OpenAI stream event was not UTF-8") }
        let value = try decodeJSON(data)
        switch value["type"]?.stringValue ?? event.event {
        case "response.created", "response.in_progress":
            guard !state.started else { return }
            state.started = true
            let response = value["response"]
            continuation.yield(.started(id: response?["id"]?.stringValue, model: response?["model"]?.stringValue.map { LLMModel($0) }))
        case "response.output_text.delta": if let delta = value["delta"]?.stringValue { continuation.yield(.textDelta(delta)) }
        case "response.output_item.added":
            guard value["item"]?["type"]?.stringValue == "function_call", let callID = value["item"]?["call_id"]?.stringValue, let name = value["item"]?["name"]?.stringValue else { return }
            if let index = value["output_index"]?.numberValue.map(Int.init) { state.callIDsByIndex[index] = callID }
            if let itemID = value["item"]?["id"]?.stringValue { state.callIDsByItemID[itemID] = callID }
            continuation.yield(.toolCallStarted(id: callID, name: name))
        case "response.function_call_arguments.delta":
            guard let delta = value["delta"]?.stringValue else { return }
            let itemID = value["item_id"]?.stringValue
            let index = value["output_index"]?.numberValue.map { Int($0) }
            let callID = itemID.flatMap { state.callIDsByItemID[$0] }
                ?? index.flatMap { state.callIDsByIndex[$0] }
            guard let callID else { throw LLMError.invalidResponse("OpenAI streamed function arguments before its function call") }
            continuation.yield(.toolCallArgumentsDelta(id: callID, jsonFragment: delta))
        case "response.completed", "response.incomplete":
            let response = try OpenAIResponsesResponseMapper().map(value["response"] ?? value)
            if let usage = response.usage { continuation.yield(.usage(usage)) }
            continuation.yield(.completed(response)); state.completed = true
        case "response.failed": _ = try OpenAIResponsesResponseMapper().map(value["response"] ?? value); throw LLMError.serverError(statusCode: nil, message: "OpenAI response failed")
        case "error": throw apiError(value, statusCode: nil, headers: [:])
        default: return
        }
    }
}

private struct OpenAICompatibleResponsesStreamState: Sendable {
    var started = false
    var completed = false
    var callIDsByIndex: [Int: String] = [:]
    var callIDsByItemID: [String: String] = [:]
}
