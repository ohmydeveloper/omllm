import Foundation

/// The common interface implemented by every provider adapter.
public protocol LLMDriver: Sendable {
    /// Stable identifier for the backing provider.
    var providerID: LLMProviderID { get }

    /// Returns features available for the requested model.
    func capabilities(for model: LLMModel?) async throws -> LLMCapabilities

    /// Fetches every model exposed by the provider's configured model endpoint.
    func listModels() async throws -> [LLMModelInfo]

    /// Performs a complete generation.
    func generate(_ request: LLMRequest) async throws -> LLMResponse

    /// Starts a semantic event stream for a generation.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
}
