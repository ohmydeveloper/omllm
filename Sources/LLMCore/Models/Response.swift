import Foundation

/// A normalized reason that generation stopped.
public enum LLMFinishReason: Equatable, Codable, Sendable {
    case completed
    case maxOutputTokens
    case toolCalls
    case contentFiltered
    case cancelled
    case unknown(String)
}

/// Normalized token accounting. Providers may omit individual values.
public struct TokenUsage: Equatable, Codable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// Sum of all token values that are present, or `nil` when none are available.
    public var totalTokens: Int? {
        guard inputTokens != nil || outputTokens != nil else { return nil }
        return (inputTokens ?? 0) + (outputTokens ?? 0)
    }
}

/// A normalized completed generation.
public struct LLMResponse: Equatable, Codable, Sendable {
    public var id: String?
    public var model: LLMModel?
    public var message: LLMMessage
    public var finishReason: LLMFinishReason
    public var usage: TokenUsage?
    public var providerMetadata: ProviderMetadata

    public init(
        id: String? = nil,
        model: LLMModel? = nil,
        message: LLMMessage,
        finishReason: LLMFinishReason,
        usage: TokenUsage? = nil,
        providerMetadata: ProviderMetadata = .init()
    ) {
        self.id = id
        self.model = model
        self.message = message
        self.finishReason = finishReason
        self.usage = usage
        self.providerMetadata = providerMetadata
    }

    /// The joined text blocks in the final assistant message.
    public var text: String { message.text }
}
