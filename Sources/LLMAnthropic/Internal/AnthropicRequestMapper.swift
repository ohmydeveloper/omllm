import Foundation
import LLMCore

/// Translation boundary for Anthropic's distinct content-block representation.
/// Canonical instructions map to system content; tools and results map to
/// Anthropic `tool_use` and `tool_result` blocks rather than OpenAI structures.
struct AnthropicRequestMapper: Sendable {
    struct Draft: Equatable, Sendable {
        let model: String
        let system: String?
        let messages: [LLMMessage]
        let tools: [LLMTool]
        let body: JSONValue
    }

    func map(
        _ request: LLMRequest,
        defaultModel: String?,
        defaultMaxOutputTokens: Int = 4_096
    ) throws -> Draft {
        guard let model = request.model?.rawValue ?? defaultModel else {
            throw LLMError.invalidRequest("An Anthropic model is required")
        }
        guard request.options.seed == nil else {
            throw LLMError.unsupportedFeature("Anthropic Messages API does not support seed")
        }
        guard case .text = request.output else {
            throw LLMError.unsupportedFeature("Anthropic Messages API does not support canonical JSON output")
        }
        let maximum = request.options.maxOutputTokens ?? defaultMaxOutputTokens
        guard maximum > 0 else {
            throw LLMError.invalidRequest("maxOutputTokens must be greater than zero")
        }

        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maximum)),
            "messages": .array(try request.messages.map(mapMessage)),
        ]
        if let instructions = request.instructions, !instructions.isEmpty {
            body["system"] = .string(instructions)
        }
        if let temperature = request.options.temperature { body["temperature"] = .number(temperature) }
        if let topP = request.options.topP { body["top_p"] = .number(topP) }
        if !request.options.stopSequences.isEmpty {
            body["stop_sequences"] = .array(request.options.stopSequences.map(JSONValue.string))
        }
        if request.toolChoice != LLMToolChoice.none, !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map(mapTool))
        }
        if let choice = request.toolChoice, choice != .none {
            guard !request.tools.isEmpty else {
                throw LLMError.invalidRequest("Anthropic tool choice requires at least one tool")
            }
            if case let .tool(name) = choice, !request.tools.contains(where: { $0.name == name }) {
                throw LLMError.invalidRequest("Anthropic tool choice references an undeclared tool")
            }
            body["tool_choice"] = mapToolChoice(choice)
        }

        return Draft(
            model: model,
            system: request.instructions,
            messages: request.messages,
            tools: request.tools,
            body: .object(body)
        )
    }

    private func mapMessage(_ message: LLMMessage) throws -> JSONValue {
        let role: String
        switch message.role {
        case .user: role = "user"
        case .assistant: role = "assistant"
        case .tool: role = "user"
        }
        let content = try message.content.map { block -> JSONValue in
            switch block {
            case let .text(text):
                guard message.role != .tool else {
                    throw LLMError.invalidRequest("Tool messages may only contain tool results")
                }
                return .object(["type": .string("text"), "text": .string(text)])
            case let .image(image):
                guard message.role == .user else {
                    throw LLMError.invalidRequest("Images are only supported in user messages")
                }
                return .object(["type": .string("image"), "source": try mediaSource(
                    url: image.url,
                    data: image.data,
                    mediaType: image.mediaType,
                    kind: "image"
                )])
            case let .document(document):
                guard message.role == .user else {
                    throw LLMError.invalidRequest("Documents are only supported in user messages")
                }
                var value: [String: JSONValue] = [
                    "type": .string("document"),
                    "source": try mediaSource(
                        url: document.url,
                        data: document.data,
                        mediaType: document.mediaType,
                        kind: "document"
                    ),
                ]
                if let filename = document.filename { value["title"] = .string(filename) }
                return .object(value)
            case let .toolCall(call):
                guard message.role == .assistant else {
                    throw LLMError.invalidRequest("Tool calls are only supported in assistant messages")
                }
                return .object([
                    "type": .string("tool_use"),
                    "id": .string(call.id),
                    "name": .string(call.name),
                    "input": call.arguments,
                ])
            case let .toolResult(result):
                guard message.role == .tool else {
                    throw LLMError.invalidRequest("Tool results must use the tool role")
                }
                return .object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(result.toolCallID),
                    "content": .string(result.content),
                    "is_error": .boolean(result.isError),
                ])
            }
        }
        return .object(["role": .string(role), "content": .array(content)])
    }

    private func mediaSource(
        url: URL?,
        data: Data?,
        mediaType: String?,
        kind: String
    ) throws -> JSONValue {
        if let url {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw LLMError.invalidRequest("An Anthropic \(kind) URL must use HTTP or HTTPS")
            }
            return .object(["type": .string("url"), "url": .string(url.absoluteString)])
        }
        guard let data, let mediaType, !mediaType.isEmpty else {
            throw LLMError.invalidRequest("An Anthropic \(kind) requires a URL or inline data with a media type")
        }
        return .object([
            "type": .string("base64"),
            "media_type": .string(mediaType),
            "data": .string(data.base64EncodedString()),
        ])
    }

    private func mapTool(_ tool: LLMTool) -> JSONValue {
        var value: [String: JSONValue] = [
            "name": .string(tool.name),
            "input_schema": tool.inputSchema,
        ]
        if let description = tool.description { value["description"] = .string(description) }
        return .object(value)
    }

    private func mapToolChoice(_ choice: LLMToolChoice) -> JSONValue {
        switch choice {
        case .auto: return .object(["type": .string("auto")])
        case .none: return .object(["type": .string("auto")])
        case .required: return .object(["type": .string("any")])
        case let .tool(name):
            return .object(["type": .string("tool"), "name": .string(name)])
        }
    }
}
