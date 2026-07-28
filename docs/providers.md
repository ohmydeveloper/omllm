# Provider Configuration

Provider configurations are immutable `Sendable` values. Their fluent methods return copies, so they are safe to derive and pass across concurrency boundaries without shared mutable configuration.

## Official OpenAI

Official OpenAI uses the OpenAI-compatible driver and the Responses dialect:

```swift
import LLMCore
import LLMOpenAICompatible

let configuration = OpenAICompatibleConfiguration.openAI(
    apiKey: openAIKey,
    defaultModel: "gpt-4.1-mini"
)
let client = LLMClient(driver: OpenAICompatibleDriver(configuration: configuration))
```

The preset configures `https://api.openai.com/v1`, bearer authentication, `POST /responses`, and `GET /models`.

## Compatible Endpoints

Supported dialects are:

- `.responses`: Responses-compatible gateways, defaulting to `POST /responses`.
- `.chatCompletions`: Chat Completions-compatible servers, defaulting to `POST /chat/completions`.

Use a Chat Completions preset for compatible servers:

```swift
let configuration = OpenAICompatibleConfiguration.openAIChatCompletions(
    baseURL: serverURL,
    apiKey: apiKey,
    defaultModel: "model-name"
)
```

Use the Ollama preset:

```swift
let configuration = OpenAICompatibleConfiguration.ollama(defaultModel: "llama3.2")
```

Configure a custom Responses-compatible gateway explicitly:

```swift
let configuration = OpenAICompatibleConfiguration(
    baseURL: gatewayURL,
    apiKey: gatewayKey,
    additionalHeaders: ["X-Gateway-Project": "example"],
    dialect: .responses,
    generationEndpointPath: "v1/responses"
)
```

## Anthropic

Anthropic remains a dedicated Messages API adapter:

```swift
import LLMAnthropic

let configuration = AnthropicConfiguration(
    apiKey: anthropicKey,
    defaultModel: "claude-sonnet-4-20250514"
)
let client = LLMClient(driver: AnthropicDriver(configuration: configuration))
```

## Fluent Copies

```swift
let configuredOpenAI = OpenAICompatibleConfiguration.openAI(apiKey: openAIKey)
    .withDefaultModel("gpt-4.1-mini")
    .withTimeout(30)
    .withHeader("X-App", value: "Example")

let configuredAnthropic = AnthropicConfiguration(apiKey: anthropicKey)
    .withDefaultModel("claude-sonnet-4-20250514")
    .withTimeout(30)
    .withBetaFeatures(["feature-name"])
```

`withHeader`, `withHeaders`, and provider-specific copy methods modify only the returned configuration.
