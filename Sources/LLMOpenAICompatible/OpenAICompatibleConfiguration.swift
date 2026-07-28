import Foundation
import LLMCore

/// The OpenAI API wire format used by an OpenAI-compatible endpoint.
public enum OpenAIAPIDialect: String, Hashable, Codable, Sendable {
    case responses
    case chatCompletions
}

/// Controls known variations among OpenAI-compatible servers.
public struct CompatibilityOptions: Equatable, Sendable {
    /// Instruction representation accepted by the server.
    public enum InstructionStyle: String, Sendable {
        case system
        case developer
        case unsupported
    }

    /// The token-limit field required by the server.
    public enum MaxTokenField: String, Sendable {
        case maxTokens
        case maxCompletionTokens
        case maxOutputTokens
    }

    /// Authentication convention used by the endpoint.
    public enum AuthenticationStyle: Equatable, Sendable {
        case bearer
        case apiKey(header: String)
        case none
    }

    public var instructionStyle: InstructionStyle
    public var supportsTools: Bool
    public var supportsImages: Bool
    public var supportsJSONObject: Bool
    public var supportsJSONSchema: Bool
    public var supportsStreamedUsage: Bool
    public var supportsModelListing: Bool
    public var maxTokenField: MaxTokenField
    public var authenticationStyle: AuthenticationStyle
    /// Generation route, relative to the configured base URL.
    public var endpointPath: String?
    /// Model catalog route, relative to the configured base URL.
    public var modelsEndpointPath: String

    public init(
        instructionStyle: InstructionStyle = .system,
        supportsTools: Bool = true,
        supportsImages: Bool = true,
        supportsJSONObject: Bool = true,
        supportsJSONSchema: Bool = false,
        supportsStreamedUsage: Bool = false,
        supportsModelListing: Bool = true,
        maxTokenField: MaxTokenField = .maxTokens,
        authenticationStyle: AuthenticationStyle = .bearer,
        endpointPath: String? = nil,
        modelsEndpointPath: String = "models"
    ) {
        self.instructionStyle = instructionStyle
        self.supportsTools = supportsTools
        self.supportsImages = supportsImages
        self.supportsJSONObject = supportsJSONObject
        self.supportsJSONSchema = supportsJSONSchema
        self.supportsStreamedUsage = supportsStreamedUsage
        self.supportsModelListing = supportsModelListing
        self.maxTokenField = maxTokenField
        self.authenticationStyle = authenticationStyle
        self.endpointPath = endpointPath
        self.modelsEndpointPath = modelsEndpointPath
    }
}

/// Connection settings for an OpenAI-compatible endpoint.
public struct OpenAICompatibleConfiguration: Equatable, Sendable {
    public static let openAIBaseURL = URL(string: "https://api.openai.com/v1")
        ?? URL(fileURLWithPath: "/")

    public var baseURL: URL
    public var apiKey: String?
    public var defaultModel: String?
    public var additionalHeaders: [String: String]
    public var organization: String?
    public var project: String?
    /// The wire format used for generation requests.
    public var dialect: OpenAIAPIDialect
    /// Generation route, relative to the configured base URL. When omitted, the dialect default is used.
    public var generationEndpointPath: String?
    /// The identity reported to logging and consumers of the driver.
    public var providerID: LLMProviderID
    public var compatibility: CompatibilityOptions
    public var timeout: TimeInterval

    public init(
        baseURL: URL,
        apiKey: String? = nil,
        defaultModel: String? = nil,
        additionalHeaders: [String: String] = [:],
        organization: String? = nil,
        project: String? = nil,
        dialect: OpenAIAPIDialect = .chatCompletions,
        generationEndpointPath: String? = nil,
        providerID: LLMProviderID = .openAICompatible,
        compatibility: CompatibilityOptions = .init(),
        timeout: TimeInterval = 60
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.defaultModel = defaultModel
        self.additionalHeaders = additionalHeaders
        self.organization = organization
        self.project = project
        self.dialect = dialect
        self.generationEndpointPath = generationEndpointPath
        self.providerID = providerID
        self.compatibility = compatibility
        self.timeout = timeout
    }

    /// Configuration for OpenAI's Responses API.
    public static func openAI(apiKey: String, defaultModel: LLMModel? = nil) -> Self {
        .init(
            baseURL: openAIBaseURL,
            apiKey: apiKey,
            defaultModel: defaultModel?.id,
            dialect: .responses,
            providerID: .openAI,
            compatibility: .openAIResponses
        )
    }

    /// Configuration preset for OpenAI-compatible Responses API endpoints.
    public static func openAIResponses(
        baseURL: URL = openAIBaseURL,
        apiKey: String? = nil,
        defaultModel: LLMModel? = nil
    ) -> Self {
        .init(
            baseURL: baseURL,
            apiKey: apiKey,
            defaultModel: defaultModel?.id,
            dialect: .responses,
            compatibility: .openAIResponses
        )
    }

    /// Configuration preset for OpenAI-compatible Chat Completions endpoints.
    public static func openAIChatCompletions(
        baseURL: URL,
        apiKey: String? = nil,
        defaultModel: LLMModel? = nil
    ) -> Self {
        .init(
            baseURL: baseURL,
            apiKey: apiKey,
            defaultModel: defaultModel?.id,
            dialect: .chatCompletions,
            compatibility: .openAIChatCompletions
        )
    }

    /// Configuration preset for Ollama's OpenAI-compatible API.
    public static func ollama(defaultModel: LLMModel? = nil) -> Self {
        .init(
            baseURL: URL(string: "http://localhost:11434/v1") ?? URL(fileURLWithPath: "/"),
            defaultModel: defaultModel?.id,
            dialect: .chatCompletions,
            compatibility: .ollama
        )
    }
}

public extension CompatibilityOptions {
    static let openAIResponses = Self(
        supportsJSONSchema: true,
        supportsStreamedUsage: false,
        maxTokenField: .maxOutputTokens,
        endpointPath: "responses"
    )

    static let openAIChatCompletions = Self(
        supportsJSONSchema: true,
        supportsStreamedUsage: true,
        maxTokenField: .maxCompletionTokens,
        endpointPath: "chat/completions"
    )

    static let ollama = Self(
        supportsJSONObject: true,
        supportsJSONSchema: true,
        supportsStreamedUsage: false,
        maxTokenField: .maxTokens,
        authenticationStyle: .none,
        endpointPath: "chat/completions"
    )
}
