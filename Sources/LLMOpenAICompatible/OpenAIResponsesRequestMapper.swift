import Foundation
import LLMCore

/// Translation boundary from canonical requests to Responses API wire values.
struct OpenAIResponsesRequestMapper: Sendable {
    struct Draft: Sendable {
        let model: String
        let body: JSONValue
    }

    func map(_ request: LLMRequest, defaultModel: String?) throws -> Draft {
        guard let model = request.model?.id ?? defaultModel else {
            throw LLMError.invalidRequest("An OpenAI model is required")
        }
        guard request.options.stopSequences.isEmpty else {
            throw LLMError.unsupportedFeature("OpenAI Responses API does not support stop sequences")
        }
        guard request.options.seed == nil else {
            throw LLMError.unsupportedFeature("OpenAI Responses API does not support seed")
        }
        var body: [String: JSONValue] = ["model": .string(model), "input": .array(try request.messages.flatMap(mapMessage))]
        if let instructions = request.instructions { body["instructions"] = .string(instructions) }
        if let value = request.options.temperature { body["temperature"] = .number(value) }
        if let value = request.options.topP { body["top_p"] = .number(value) }
        if let value = request.options.maxOutputTokens {
            guard value > 0 else { throw LLMError.invalidRequest("maxOutputTokens must be greater than zero") }
            body["max_output_tokens"] = .number(Double(value))
        }
        if !request.tools.isEmpty { body["tools"] = .array(request.tools.map(mapTool)) }
        if let choice = request.toolChoice { body["tool_choice"] = mapToolChoice(choice) }
        body["text"] = .object(["format": mapOutput(request.output)])
        return .init(model: model, body: .object(body))
    }

    private func mapMessage(_ message: LLMMessage) throws -> [JSONValue] {
        var content: [JSONValue] = []
        var items: [JSONValue] = []
        func appendMessage() {
            guard !content.isEmpty else { return }
            items.append(.object(["type": .string("message"), "role": .string(message.role.rawValue), "content": .array(content)]))
            content.removeAll(keepingCapacity: true)
        }
        for item in message.content {
            switch item {
            case let .text(text):
                guard message.role != .tool else { throw LLMError.invalidRequest("Tool messages may only contain tool results") }
                content.append(.object(["type": .string("input_text"), "text": .string(text)]))
            case let .image(image):
                guard message.role == .user else { throw LLMError.invalidRequest("Images are only supported in user messages") }
                content.append(.object(["type": .string("input_image"), "detail": .string("auto"), "image_url": .string(try imageURL(image))]))
            case let .document(document):
                guard message.role == .user else { throw LLMError.invalidRequest("Documents are only supported in user messages") }
                content.append(.object(try documentFields(document)))
            case let .toolCall(call):
                guard message.role == .assistant else { throw LLMError.invalidRequest("Tool calls are only supported in assistant messages") }
                appendMessage()
                items.append(.object(["type": .string("function_call"), "call_id": .string(call.id), "name": .string(call.name), "arguments": .string(try jsonString(call.arguments))]))
            case let .toolResult(result):
                guard message.role == .tool else { throw LLMError.invalidRequest("Tool results must use the tool role") }
                appendMessage()
                items.append(.object(["type": .string("function_call_output"), "call_id": .string(result.toolCallID), "output": .string(result.content)]))
            }
        }
        appendMessage()
        return items
    }

    private func imageURL(_ image: LLMImage) throws -> String {
        if let url = image.url { return url.absoluteString }
        guard let data = image.data, let mediaType = image.mediaType, !mediaType.isEmpty else { throw LLMError.invalidRequest("An image requires a URL or inline data with a media type") }
        return "data:\(mediaType);base64,\(data.base64EncodedString())"
    }

    private func documentFields(_ document: LLMDocument) throws -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["type": .string("input_file")]
        if let url = document.url { fields["file_url"] = .string(url.absoluteString) }
        else if let data = document.data {
            guard let mediaType = document.mediaType, !mediaType.isEmpty else { throw LLMError.invalidRequest("An inline document requires a media type") }
            fields["file_data"] = .string("data:\(mediaType);base64,\(data.base64EncodedString())")
        } else { throw LLMError.invalidRequest("A document requires a URL or inline data") }
        if let filename = document.filename { fields["filename"] = .string(filename) }
        return fields
    }

    private func mapTool(_ tool: LLMTool) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("function"), "name": .string(tool.name), "parameters": tool.inputSchema]
        if let description = tool.description { value["description"] = .string(description) }
        return .object(value)
    }

    private func mapToolChoice(_ choice: LLMToolChoice) -> JSONValue {
        switch choice { case .auto: .string("auto"); case .none: .string("none"); case .required: .string("required"); case let .tool(name): .object(["type": .string("function"), "name": .string(name)]) }
    }

    private func mapOutput(_ output: OutputConfiguration) -> JSONValue {
        switch output {
        case .text: .object(["type": .string("text")])
        case .jsonObject: .object(["type": .string("json_object")])
        case let .jsonSchema(name, schema, strict): .object(["type": .string("json_schema"), "name": .string(name), "schema": schema, "strict": .boolean(strict)])
        }
    }

    private func jsonString(_ value: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else { throw LLMError.invalidRequest("Tool arguments could not be encoded as UTF-8 JSON") }
        return string
    }
}
