import Foundation
import LLMCore

/// Translation boundary from Responses API wire values to canonical responses.
struct OpenAIResponsesResponseMapper: Sendable {
    func map(_ value: JSONValue) throws -> LLMResponse {
        guard let object = value.objectValue else { throw LLMError.invalidResponse("OpenAI response was not a JSON object") }
        if object["status"]?.stringValue == "failed" {
            throw LLMError.serverError(statusCode: nil, message: object["error"]?["message"]?.stringValue ?? "OpenAI response failed")
        }
        var content: [LLMContent] = []
        for item in object["output"]?.arrayValue ?? [] {
            switch item["type"]?.stringValue {
            case "message":
                for part in item["content"]?.arrayValue ?? [] {
                    if let text = part["text"]?.stringValue { content.append(.text(text)) }
                    else if let refusal = part["refusal"]?.stringValue { content.append(.text(refusal)) }
                }
            case "function_call":
                guard let id = item["call_id"]?.stringValue, let name = item["name"]?.stringValue else { throw LLMError.invalidResponse("OpenAI returned an incomplete function call") }
                content.append(.toolCall(.init(id: id, name: name, arguments: try decodeArguments(item["arguments"]?.stringValue ?? "{}"))))
            default: continue
            }
        }
        let status = object["status"]?.stringValue
        let incompleteReason = object["incomplete_details"]?["reason"]?.stringValue
        let finishReason: LLMFinishReason
        if content.contains(where: { if case .toolCall = $0 { true } else { false } }) { finishReason = .toolCalls }
        else {
            switch status {
            case "completed": finishReason = .completed
            case "cancelled": finishReason = .cancelled
            case "incomplete":
                switch incompleteReason { case "max_output_tokens": finishReason = .maxOutputTokens; case "content_filter": finishReason = .contentFiltered; case let reason?: finishReason = .unknown(reason); case nil: finishReason = .unknown("incomplete") }
            case let status?: finishReason = .unknown(status)
            case nil: finishReason = .unknown("unknown")
            }
        }
        var metadata: [String: JSONValue] = [:]
        for key in ["status", "created_at", "incomplete_details", "error", "metadata", "usage"] { if let value = object[key] { metadata[key] = value } }
        let model = object["model"]?.stringValue.map { LLMModel($0) }
        return .init(id: object["id"]?.stringValue, model: model, message: .init(role: .assistant, content: content), finishReason: finishReason, usage: mapUsage(object["usage"]), providerMetadata: .init(metadata))
    }

    func mapUsage(_ value: JSONValue?) -> TokenUsage? {
        guard let value else { return nil }
        let input = value["input_tokens"]?.numberValue.map(Int.init)
        let output = value["output_tokens"]?.numberValue.map(Int.init)
        guard input != nil || output != nil else { return nil }
        return .init(inputTokens: input, outputTokens: output)
    }

    func mapText(_ text: String, id: String?, model: String?) -> LLMResponse {
        .init(
            id: id,
            model: model.map { LLMModel($0) },
            message: .assistant(text),
            finishReason: .completed
        )
    }

    private func decodeArguments(_ string: String) throws -> JSONValue {
        guard let data = string.data(using: .utf8) else { throw LLMError.invalidResponse("Function call arguments were not UTF-8") }
        do { return try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw LLMError.invalidResponse("Function call arguments were not valid JSON") }
    }
}
