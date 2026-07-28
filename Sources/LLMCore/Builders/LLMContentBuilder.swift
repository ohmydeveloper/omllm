import Foundation

/// Builds ordered provider-neutral content blocks for a chat message.
@resultBuilder
public enum LLMContentBuilder {
    public static func buildExpression(_ expression: LLMContent) -> [LLMContent] { [expression] }
    public static func buildBlock(_ components: [LLMContent]...) -> [LLMContent] { components.flatMap { $0 } }
    public static func buildOptional(_ component: [LLMContent]?) -> [LLMContent] { component ?? [] }
    public static func buildEither(first component: [LLMContent]) -> [LLMContent] { component }
    public static func buildEither(second component: [LLMContent]) -> [LLMContent] { component }
    public static func buildArray(_ components: [[LLMContent]]) -> [LLMContent] { components.flatMap { $0 } }
}

public extension LLMContent {
    /// Creates a text content block for use with `LLMContentBuilder`.
    static func textContent(_ text: String) -> Self { .text(text) }

    /// Creates an inline image content block.
    static func image(data: Data, mediaType: String) -> Self {
        .image(.init(data: data, mediaType: mediaType))
    }

    /// Creates a URL-backed image content block.
    static func image(url: URL, mediaType: String? = nil) -> Self {
        .image(.init(url: url, mediaType: mediaType))
    }

    /// Creates an inline document content block.
    static func document(data: Data, mediaType: String, filename: String? = nil) -> Self {
        .document(.init(data: data, mediaType: mediaType, filename: filename))
    }

    /// Creates a URL-backed document content block.
    static func document(url: URL, mediaType: String? = nil, filename: String? = nil) -> Self {
        .document(.init(url: url, mediaType: mediaType, filename: filename))
    }
}

public extension LLMMessage {
    /// Creates a user message with ordered text, image, and document content blocks.
    static func user(@LLMContentBuilder content: () -> [LLMContent]) -> Self {
        .init(role: .user, content: content())
    }

    /// Creates an assistant message with ordered content blocks.
    static func assistant(@LLMContentBuilder content: () -> [LLMContent]) -> Self {
        .init(role: .assistant, content: content())
    }
}
