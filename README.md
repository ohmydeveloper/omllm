# omllm

A dependency-free Swift SDK for multi-provider LLM chat inference.

`omllm` provides one type-safe API for requests, streaming, tools, model catalogs, images, and documents while keeping provider HTTP formats behind dedicated drivers.

| Provider | Driver | API dialect |
| --- | --- | --- |
| Official OpenAI | `OpenAICompatibleDriver` | Responses |
| OpenAI-compatible servers | `OpenAICompatibleDriver` | Responses or Chat Completions |
| Anthropic | `AnthropicDriver` | Messages |

## Features

- Canonical `LLMRequest`, `LLMMessage`, `LLMContent`, `LLMResponse`, and `LLMEvent` types.
- One-shot generation and semantic SSE streaming.
- OpenAI Responses and Chat Completions dialects through one driver.
- Anthropic Messages API support with paginated model listing.
- Text, image, and document chat attachments from `Data` or `URL` sources.
- Tool calling, JSON object output, JSON Schema output, usage, and normalized finish reasons where supported.
- Optional result-builder DSL for readable multi-part requests.
- Immutable, fluent provider configuration values.
- Mock driver support for consumer tests.

> [!NOTE]
> Attachment, tool, and structured-output support depends on the selected provider, dialect, and model. Unsupported canonical features fail explicitly with `LLMError.unsupportedFeature`; the SDK never silently drops them.

## Requirements

- Swift 6
- iOS 16+, macOS 13+, tvOS 16+, or watchOS 9+

## Installation

Add the package in Xcode, then select the products required by your app:

- `LLMCore`: canonical types, client, transport, streaming, and errors.
- `LLMOpenAICompatible`: official OpenAI and OpenAI-compatible endpoints.
- `LLMAnthropic`: Anthropic Messages API.
- `LLMTestSupport`: deterministic mock driver for tests.

For Swift Package Manager, add this package to your dependencies and use the relevant products:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "LLMCore", package: "omllm"),
        .product(name: "LLMOpenAICompatible", package: "omllm")
    ]
)
```

## Quick Start

Official OpenAI is configured through the OpenAI-compatible driver. The official preset uses the Responses API dialect:

```swift
import LLMCore
import LLMOpenAICompatible

let driver = OpenAICompatibleDriver(configuration: .openAI(
    apiKey: openAIKey,
    defaultModel: "gpt-4.1-mini"
))
let client = LLMClient(driver: driver)

let response = try await client.generate(.init(
    instructions: "Reply briefly in English.",
    messages: [.user("Explain Swift protocols.")]
))

print(response.text)
```

## Providers

### OpenAI-Compatible

`OpenAICompatibleDriver` is the single OpenAI implementation. It supports two public dialects:

- `.responses`: `POST /responses`; used by the official OpenAI preset and Responses-compatible gateways.
- `.chatCompletions`: `POST /chat/completions`; used by Ollama, LM Studio, vLLM, LiteLLM, Groq, Together, and standard compatible servers.

```swift
let configuration = OpenAICompatibleConfiguration.openAIChatCompletions(
    baseURL: serverURL,
    apiKey: apiKey,
    defaultModel: "model-name"
)
let client = LLMClient(driver: OpenAICompatibleDriver(configuration: configuration))
```

For Ollama:

```swift
let configuration = OpenAICompatibleConfiguration.ollama(defaultModel: "llama3.2")
```

For a Responses-compatible gateway, select the dialect explicitly:

```swift
let configuration = OpenAICompatibleConfiguration(
    baseURL: gatewayURL,
    apiKey: gatewayKey,
    additionalHeaders: ["X-Gateway-Project": "example"],
    dialect: .responses,
    generationEndpointPath: "v1/responses"
)
```

### Anthropic

Anthropic uses its own dedicated Messages API adapter:

```swift
import LLMAnthropic

let driver = AnthropicDriver(configuration: .init(
    apiKey: anthropicKey,
    defaultModel: "claude-sonnet-4-20250514"
))
let client = LLMClient(driver: driver)
```

## Requests And Attachments

Direct value construction is the primary API. Messages preserve the order of their content blocks:

```swift
let request = LLMRequest(
    model: "gpt-4.1-mini",
    instructions: "Describe the supplied material.",
    messages: [
        .init(role: .user, content: [
            .text("What is in this image and PDF?"),
            .image(.init(data: imageData, mediaType: "image/png")),
            .document(.init(url: pdfURL, mediaType: "application/pdf", filename: "guide.pdf")),
        ])
    ],
    options: .init(temperature: 0.2, maxOutputTokens: 300)
)
```

Images and documents are regular input attachments, not persistent provider files. They accept in-memory bytes or URLs. PDF is supported as a common document format.

### Optional Builder DSL

Use the builder when multi-part message construction is clearer than nested initializers:

```swift
let request = try LLMRequest.build {
    LLMRequestComponent.model("gpt-4.1-mini")
    LLMRequestComponent.instructions("Describe the supplied material.")
    LLMRequestComponent.temperature(0.2)
    LLMRequestComponent.maxOutputTokens(300)
    LLMRequestComponent.user {
        LLMContent.textContent("What is in this image and PDF?")
        LLMContent.image(data: imageData, mediaType: "image/png")
        LLMContent.document(url: pdfURL, mediaType: "application/pdf", filename: "guide.pdf")
    }
}
```

Builder blocks support `if` and `for`. The throwing build catches local structural problems, such as duplicate singleton fields, empty message content, invalid attachment metadata, and invalid option values. Provider/model capability checks stay with the driver.

## Streaming And Models

List models through the provider-neutral client:

```swift
let models = try await client.listModels()
for model in models {
    print(model.model.id, model.displayName ?? "")
}
```

Stream normalized events instead of provider-specific SSE payloads:

```swift
for try await event in client.stream(.text("Write one sentence.")) {
    switch event {
    case let .textDelta(text):
        print(text, terminator: "")
    case let .completed(response):
        print("\nFinished: \(response.finishReason)")
    default:
        break
    }
}
```

## Immutable Configuration

Provider configurations are `Sendable` value types. Fluent APIs return a modified copy and never mutate shared state:

```swift
let openAI = OpenAICompatibleConfiguration.openAI(apiKey: openAIKey)
    .withDefaultModel("gpt-4.1-mini")
    .withTimeout(30)
    .withHeader("X-App", value: "My App")

let anthropic = AnthropicConfiguration(apiKey: anthropicKey)
    .withDefaultModel("claude-sonnet-4-20250514")
    .withTimeout(30)
```

## Architecture

```text
Application -> LLMClient -> LLMDriver -> LLMTransport -> Provider API
```

`LLMCore` contains only stable provider-neutral concepts. Provider-specific wire models, endpoints, headers, SSE event names, and feature extensions stay inside their owning modules.

The package intentionally does not include provider platform APIs such as remote file lifecycle management, batches, assistants, vector stores, hosted tools, or infrastructure controls.

## Documentation

- [Architecture](docs/architecture.md)
- [Requests and attachments](docs/requests.md)
- [Provider configuration](docs/providers.md)
- [Streaming and model catalogs](docs/streaming-and-models.md)
- [Migration to unified OpenAI support](docs/migration.md)

## Development

```bash
swift build
swift test
```
