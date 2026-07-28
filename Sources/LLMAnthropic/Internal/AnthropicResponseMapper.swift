import Foundation
import LLMCore

/// Translation boundary from Anthropic content blocks to canonical responses.
struct AnthropicResponseMapper: Sendable {
    func map(_ value: JSONValue) throws -> LLMResponse {
        guard let object = value.objectValue else {
            throw LLMError.invalidResponse("Anthropic response was not a JSON object")
        }
        if object["type"]?.stringValue == "error" {
            let message = object["error"]?["message"]?.stringValue ?? "Anthropic API request failed"
            throw LLMError.serverError(statusCode: nil, message: message)
        }
        guard let content = object["content"]?.arrayValue else {
            throw LLMError.invalidResponse("Anthropic response did not contain content")
        }
        let blocks = try content.compactMap(mapContent)
        let stopReason = object["stop_reason"]?.stringValue
        var metadata: [String: JSONValue] = [:]
        if let sequence = object["stop_sequence"] { metadata["stop_sequence"] = sequence }
        if let usage = object["usage"], let usageObject = usage.objectValue {
            for (key, item) in usageObject where !["input_tokens", "output_tokens"].contains(key) {
                metadata["usage_\(key)"] = item
            }
        }
        return .init(
            id: object["id"]?.stringValue,
            model: object["model"]?.stringValue.map { LLMModel($0) },
            message: .init(role: .assistant, content: blocks),
            finishReason: finishReason(stopReason),
            usage: usage(object["usage"]),
            providerMetadata: .init(metadata)
        )
    }

    func mapText(_ text: String, id: String?, model: String?) -> LLMResponse {
        .init(
            id: id,
            model: model.map { LLMModel(rawValue: $0) },
            message: .assistant(text),
            finishReason: .completed
        )
    }

    func finishReason(_ reason: String?) -> LLMFinishReason {
        switch reason {
        case "end_turn", "stop_sequence", "pause_turn": return .completed
        case "max_tokens": return .maxOutputTokens
        case "tool_use": return .toolCalls
        case "refusal": return .contentFiltered
        case let reason?: return .unknown(reason)
        case nil: return .unknown("missing_stop_reason")
        }
    }

    func usage(_ value: JSONValue?) -> TokenUsage? {
        guard let value = value?.objectValue else { return nil }
        let input = value["input_tokens"]?.numberValue.map(Int.init)
        let output = value["output_tokens"]?.numberValue.map(Int.init)
        guard input != nil || output != nil else { return nil }
        return .init(inputTokens: input, outputTokens: output)
    }

    private func mapContent(_ value: JSONValue) throws -> LLMContent? {
        switch value["type"]?.stringValue {
        case "text":
            guard let text = value["text"]?.stringValue else {
                throw LLMError.invalidResponse("Anthropic text block did not contain text")
            }
            return .text(text)
        case "tool_use":
            guard let id = value["id"]?.stringValue,
                  let name = value["name"]?.stringValue,
                  let input = value["input"] else {
                throw LLMError.invalidResponse("Anthropic tool_use block was incomplete")
            }
            return .toolCall(.init(id: id, name: name, arguments: input))
        default:
            return nil
        }
    }
}
