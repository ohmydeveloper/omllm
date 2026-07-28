import Foundation

/// A canonical message role. Instructions are represented separately on `LLMRequest`.
public enum LLMRole: String, Codable, Sendable {
    case user
    case assistant
    case tool
}

/// Image input represented by either a remote URL or inline bytes.
public struct LLMImage: Equatable, Codable, Sendable {
    public var url: URL?
    public var data: Data?
    public var mediaType: String?

    public init(url: URL, mediaType: String? = nil) {
        self.url = url
        self.data = nil
        self.mediaType = mediaType
    }

    public init(data: Data, mediaType: String) {
        self.url = nil
        self.data = data
        self.mediaType = mediaType
    }
}

/// Document input represented by inline bytes and its media type.
public struct LLMDocument: Equatable, Codable, Sendable {
    public var url: URL?
    public var data: Data?
    public var mediaType: String?
    public var filename: String?

    public init(data: Data, mediaType: String, filename: String? = nil) {
        self.url = nil
        self.data = data
        self.mediaType = mediaType
        self.filename = filename
    }

    public init(url: URL, mediaType: String? = nil, filename: String? = nil) {
        self.url = url
        self.data = nil
        self.mediaType = mediaType
        self.filename = filename
    }
}

/// A model-requested tool invocation.
public struct LLMToolCall: Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// The result supplied for a previous tool invocation.
public struct LLMToolResult: Equatable, Codable, Sendable {
    public var toolCallID: String
    public var content: String
    public var isError: Bool

    public init(toolCallID: String, content: String, isError: Bool = false) {
        self.toolCallID = toolCallID
        self.content = content
        self.isError = isError
    }
}

/// One canonical message content block.
public enum LLMContent: Equatable, Codable, Sendable {
    case text(String)
    case image(LLMImage)
    case document(LLMDocument)
    case toolCall(LLMToolCall)
    case toolResult(LLMToolResult)
}

/// A canonical conversation message.
public struct LLMMessage: Equatable, Codable, Sendable {
    public var role: LLMRole
    public var content: [LLMContent]

    public init(role: LLMRole, content: [LLMContent]) {
        self.role = role
        self.content = content
    }

    /// Creates a user message containing one text block.
    public static func user(_ text: String) -> Self {
        Self(role: .user, content: [.text(text)])
    }

    /// Creates an assistant message containing one text block.
    public static func assistant(_ text: String) -> Self {
        Self(role: .assistant, content: [.text(text)])
    }

    /// Creates a tool message containing one tool result block.
    public static func toolResult(
        toolCallID: String,
        content: String,
        isError: Bool = false
    ) -> Self {
        Self(
            role: .tool,
            content: [.toolResult(.init(toolCallID: toolCallID, content: content, isError: isError))]
        )
    }

    /// Creates a tool message containing one or more tool results.
    public static func tool(results: [LLMToolResult]) -> Self {
        Self(role: .tool, content: results.map(LLMContent.toolResult))
    }

    /// Text blocks joined in order, excluding non-text content.
    public var text: String {
        content.compactMap { block in
            guard case let .text(text) = block else { return nil }
            return text
        }.joined()
    }
}
