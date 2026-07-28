import Foundation

/// A stable provider identifier. Custom drivers may define additional values.
public struct LLMProviderID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let openAI = Self(rawValue: "openai")
    public static let anthropic = Self(rawValue: "anthropic")
    public static let openAICompatible = Self(rawValue: "openai-compatible")
}

/// A provider model identifier.
public struct LLMModel: Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let id: String

    public init(_ id: String) {
        self.id = id
    }

    public init(stringLiteral value: String) { self.init(value) }

    /// Compatibility alias for APIs that represent identifiers as raw values.
    public var rawValue: String { id }

    public init(rawValue: String) { self.init(rawValue) }
}

/// Arbitrary metadata returned by a provider, kept separate from canonical fields.
public struct ProviderMetadata: Hashable, Codable, Sendable {
    public var additionalValues: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) {
        self.additionalValues = values
    }

    public subscript(key: String) -> JSONValue? { additionalValues[key] }
}

/// Information returned by a provider's model catalog.
public struct LLMModelInfo: Hashable, Sendable {
    public let model: LLMModel
    public let displayName: String?
    public let ownedBy: String?
    public let createdAt: Date?
    public let capabilities: LLMCapabilities?
    public let metadata: ProviderMetadata

    public init(
        model: LLMModel,
        displayName: String? = nil,
        ownedBy: String? = nil,
        createdAt: Date? = nil,
        capabilities: LLMCapabilities? = nil,
        metadata: ProviderMetadata = .init()
    ) {
        self.model = model
        self.displayName = displayName
        self.ownedBy = ownedBy
        self.createdAt = createdAt
        self.capabilities = capabilities
        self.metadata = metadata
    }
}

/// A page of models, including an optional provider continuation token.
public struct LLMModelList: Hashable, Sendable {
    public let models: [LLMModelInfo]
    public let nextPageToken: String?

    public init(models: [LLMModelInfo], nextPageToken: String? = nil) {
        self.models = models
        self.nextPageToken = nextPageToken
    }
}
