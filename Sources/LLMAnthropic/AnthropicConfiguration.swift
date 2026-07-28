import Foundation

/// Connection settings for the Anthropic Messages API.
public struct AnthropicConfiguration: Equatable, Sendable {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")
        ?? URL(fileURLWithPath: "/")

    public var apiKey: String
    public var baseURL: URL
    public var apiVersion: String
    public var defaultModel: String?
    public var additionalHeaders: [String: String]
    public var betaFeatures: [String]
    public var timeout: TimeInterval
    public var defaultMaxOutputTokens: Int

    public init(
        apiKey: String,
        baseURL: URL = Self.defaultBaseURL,
        apiVersion: String = "2023-06-01",
        defaultModel: String? = nil,
        additionalHeaders: [String: String] = [:],
        betaFeatures: [String] = [],
        timeout: TimeInterval = 60,
        defaultMaxOutputTokens: Int = 4_096
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.apiVersion = apiVersion
        self.defaultModel = defaultModel
        self.additionalHeaders = additionalHeaders
        self.betaFeatures = betaFeatures
        self.timeout = timeout
        self.defaultMaxOutputTokens = defaultMaxOutputTokens
    }
}
