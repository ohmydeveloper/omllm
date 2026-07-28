import Foundation
import LLMCore

/// A deterministic driver for tests and previews of library integrations.
public struct MockLLMDriver: LLMDriver {
    public let providerID: LLMProviderID
    public var configuredCapabilities: LLMCapabilities
    public var response: LLMResponse
    public var models: [LLMModelInfo]
    public var events: [LLMEvent]
    public var capabilitiesError: LLMError?
    public var generationError: LLMError?
    public var modelListError: LLMError?
    public var streamingError: LLMError?

    public init(
        providerID: LLMProviderID = .init(rawValue: "mock"),
        capabilities: LLMCapabilities = .init(supportsStreaming: true),
        response: LLMResponse = .init(message: .assistant(""), finishReason: .completed),
        models: [LLMModelInfo] = [],
        events: [LLMEvent] = [],
        capabilitiesError: LLMError? = nil,
        generationError: LLMError? = nil,
        modelListError: LLMError? = nil,
        streamingError: LLMError? = nil
    ) {
        self.providerID = providerID
        self.configuredCapabilities = capabilities
        self.response = response
        self.models = models
        self.events = events
        self.capabilitiesError = capabilitiesError
        self.generationError = generationError
        self.modelListError = modelListError
        self.streamingError = streamingError
    }

    public func listModels() async throws -> [LLMModelInfo] {
        if let modelListError { throw modelListError }
        return models
    }

    public func capabilities(for model: LLMModel?) async throws -> LLMCapabilities {
        if let capabilitiesError { throw capabilitiesError }
        return configuredCapabilities
    }

    public func generate(_ request: LLMRequest) async throws -> LLMResponse {
        if let generationError { throw generationError }
        return response
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            if let streamingError {
                continuation.finish(throwing: streamingError)
                return
            }
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}
