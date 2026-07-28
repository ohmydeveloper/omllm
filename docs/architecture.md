# Architecture

`omllm` separates stable chat concepts from provider wire formats:

```text
Application -> LLMClient -> LLMDriver -> LLMTransport -> Provider API
```

`LLMCore` owns canonical values such as `LLMRequest`, `LLMMessage`, `LLMContent`, `LLMResponse`, `LLMEvent`, `LLMError`, and `LLMModelInfo`. It does not import provider modules.

`LLMDriver` is intentionally small:

```swift
public protocol LLMDriver: Sendable {
    var providerID: LLMProviderID { get }
    func capabilities(for model: LLMModel?) async throws -> LLMCapabilities
    func listModels() async throws -> [LLMModelInfo]
    func generate(_ request: LLMRequest) async throws -> LLMResponse
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
}
```

`LLMClient` is a thin facade over a driver. Use it when application code should be independent of a concrete provider:

```swift
let client = LLMClient(driver: driver)
let response = try await client.generate(.text("Explain actor isolation."))
```

## Providers

`AnthropicDriver` owns Anthropic Messages API request, response, streaming, and pagination mappings.

`OpenAICompatibleDriver` is the single implementation for supported OpenAI API dialects. It supports both `OpenAIAPIDialect.responses` and `OpenAIAPIDialect.chatCompletions`; dialects have separate internal request, response, and SSE mappings.

Provider-specific features do not enter `LLMCore` until they have stable and honest cross-provider semantics. A requested canonical feature that a selected provider, dialect, or configuration cannot map fails explicitly with `LLMError.unsupportedFeature`.
