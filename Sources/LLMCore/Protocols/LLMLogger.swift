import Foundation

/// Optional metadata-only logging hook. Prompt and response content are never supplied.
public protocol LLMLogger: Sendable {
    /// Records non-content metadata for a request.
    func logRequest(provider: LLMProviderID, metadata: [String: JSONValue])

    /// Records non-content metadata after a successful request.
    func logCompletion(provider: LLMProviderID, metadata: [String: JSONValue])

    /// Records normalized failure metadata.
    func logFailure(provider: LLMProviderID, error: LLMError, metadata: [String: JSONValue])
}

public extension LLMLogger {
    func logCompletion(provider: LLMProviderID, metadata: [String: JSONValue]) {}
}
