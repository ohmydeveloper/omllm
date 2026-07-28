import Foundation
import LLMCore

public extension OpenAICompatibleConfiguration {
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

    /// Returns a copy with additional HTTP headers merged by name.
    func withHeaders(_ headers: [String: String]) -> Self {
        var copy = self
        copy.additionalHeaders.merge(headers) { _, new in new }
        return copy
    }
}
