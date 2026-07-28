import Foundation

/// A thin provider-independent facade over an `LLMDriver`.
public struct LLMClient: Sendable {
    private let driver: any LLMDriver

    public init(driver: any LLMDriver) {
        self.driver = driver
    }

    /// Returns the driver's capabilities for a model.
    public func capabilities(for model: LLMModel? = nil) async throws -> LLMCapabilities {
        try await driver.capabilities(for: model)
    }

    /// Fetches all models available from the driver.
    public func listModels() async throws -> [LLMModelInfo] {
        try await driver.listModels()
    }

    /// Delegates a complete generation to the driver.
    public func generate(_ request: LLMRequest) async throws -> LLMResponse {
        try await driver.generate(request)
    }

    /// Delegates semantic streaming generation to the driver.
    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        driver.stream(request)
    }
}
