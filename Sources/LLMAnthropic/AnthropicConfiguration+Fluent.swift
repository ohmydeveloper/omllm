import Foundation
import LLMCore

public extension AnthropicConfiguration {
    /// Returns a copy with the default model changed.
    func withDefaultModel(_ model: LLMModel?) -> Self {
        var copy = self
        copy.defaultModel = model?.id
        return copy
    }

    /// Returns a copy with the request timeout changed.
    func withTimeout(_ timeout: TimeInterval) -> Self {
        var copy = self
        copy.timeout = timeout
        return copy
    }

    /// Returns a copy with one additional HTTP header.
    func withHeader(_ name: String, value: String) -> Self {
        var copy = self
        copy.additionalHeaders[name] = value
        return copy
    }

    /// Returns a copy with beta feature identifiers replaced.
    func withBetaFeatures(_ features: [String]) -> Self {
        var copy = self
        copy.betaFeatures = features
        return copy
    }
}
