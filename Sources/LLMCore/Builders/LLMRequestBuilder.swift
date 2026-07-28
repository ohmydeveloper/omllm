import Foundation

/// A typed component used by `LLMRequestBuilder`.
public enum LLMRequestComponent: Sendable {
    case model(LLMModel)
    case instructions(String)
    case options(GenerationOptions)
    case message(LLMMessage)
}

/// Builds an `LLMRequest` from canonical request components.
@resultBuilder
public enum LLMRequestBuilder {
    public static func buildExpression(_ expression: LLMRequestComponent) -> [LLMRequestComponent] { [expression] }
    public static func buildBlock(_ components: [LLMRequestComponent]...) -> [LLMRequestComponent] { components.flatMap { $0 } }
    public static func buildOptional(_ component: [LLMRequestComponent]?) -> [LLMRequestComponent] { component ?? [] }
    public static func buildEither(first component: [LLMRequestComponent]) -> [LLMRequestComponent] { component }
    public static func buildEither(second component: [LLMRequestComponent]) -> [LLMRequestComponent] { component }
    public static func buildArray(_ components: [[LLMRequestComponent]]) -> [LLMRequestComponent] { components.flatMap { $0 } }
}

public extension LLMRequestComponent {
    static func temperature(_ value: Double) -> Self { .options(.init(temperature: value)) }
    static func maxOutputTokens(_ value: Int) -> Self { .options(.init(maxOutputTokens: value)) }
    static func user(_ message: LLMMessage) -> Self { .message(message) }
    static func assistant(_ message: LLMMessage) -> Self { .message(message) }
    static func user(@LLMContentBuilder content: () -> [LLMContent]) -> Self {
        .message(.user(content: content))
    }
    static func assistant(@LLMContentBuilder content: () -> [LLMContent]) -> Self {
        .message(.assistant(content: content))
    }
}

public extension LLMRequest {
    /// Builds a canonical request while validating local structural invariants.
    ///
    /// Provider and model capabilities are deliberately not checked here. Drivers reject
    /// unsupported canonical features before sending a request.
    static func build(@LLMRequestBuilder _ content: () -> [LLMRequestComponent]) throws -> Self {
        var model: LLMModel?
        var instructions: String?
        var options: GenerationOptions?
        var messages: [LLMMessage] = []

        for component in content() {
            switch component {
            case let .model(value):
                guard model == nil else { throw LLMError.invalidRequest("Request builder received more than one model") }
                model = value
            case let .instructions(value):
                guard instructions == nil else { throw LLMError.invalidRequest("Request builder received more than one instructions field") }
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LLMError.invalidRequest("Instructions must not be empty")
                }
                instructions = value
            case let .options(value):
                guard options == nil else { throw LLMError.invalidRequest("Request builder received more than one options field") }
                try LLMRequestBuilderValidation.validate(options: value)
                options = value
            case let .message(message):
                try LLMRequestBuilderValidation.validate(content: message.content)
                messages.append(message)
            }
        }

        guard !messages.isEmpty else { throw LLMError.invalidRequest("A request must contain at least one message") }
        return .init(model: model, instructions: instructions, messages: messages, options: options ?? .init())
    }
}

enum LLMRequestBuilderValidation {
    static func validate(options: GenerationOptions) throws {
        if let temperature = options.temperature, !(0...2).contains(temperature) {
            throw LLMError.invalidRequest("Temperature must be between 0 and 2")
        }
        if let topP = options.topP, !(0...1).contains(topP) {
            throw LLMError.invalidRequest("topP must be between 0 and 1")
        }
        if let maxOutputTokens = options.maxOutputTokens, maxOutputTokens <= 0 {
            throw LLMError.invalidRequest("maxOutputTokens must be greater than zero")
        }
    }

    static func validate(content: [LLMContent]) throws {
        guard !content.isEmpty else { throw LLMError.invalidRequest("A message must contain content") }
        for item in content {
            switch item {
            case let .text(text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LLMError.invalidRequest("Text content must not be empty")
                }
            case let .image(image):
                try validate(data: image.data, url: image.url, mediaType: image.mediaType, expectedPrefix: "image/", label: "Image")
            case let .document(document):
                try validate(data: document.data, url: document.url, mediaType: document.mediaType, expectedPrefix: nil, label: "Document")
                if let filename = document.filename, filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw LLMError.invalidRequest("Document filename must not be empty")
                }
            case .toolCall, .toolResult:
                continue
            }
        }
    }

    private static func validate(data: Data?, url: URL?, mediaType: String?, expectedPrefix: String?, label: String) throws {
        guard (data == nil) != (url == nil) else { throw LLMError.invalidRequest("\(label) must have exactly one source") }
        if let data, data.isEmpty { throw LLMError.invalidRequest("\(label) data must not be empty") }
        if let mediaType {
            guard !mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  expectedPrefix.map({ mediaType.lowercased().hasPrefix($0) }) ?? true else {
                throw LLMError.invalidRequest("\(label) media type is invalid")
            }
        } else if data != nil {
            throw LLMError.invalidRequest("Inline \(label.lowercased()) data requires a media type")
        }
    }
}
