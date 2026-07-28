# Migration To Unified OpenAI Support

The package no longer exposes a standalone `LLMOpenAI` module or `OpenAIDriver`. OpenAI support is provided by `LLMOpenAICompatible` so official OpenAI and compatible gateways use one dialect-aware implementation.

Replace:

```swift
import LLMOpenAI

let driver = OpenAIDriver(configuration: .init(
    apiKey: apiKey,
    defaultModel: "gpt-4.1-mini"
))
```

With:

```swift
import LLMOpenAICompatible

let driver = OpenAICompatibleDriver(configuration: .openAI(
    apiKey: apiKey,
    defaultModel: "gpt-4.1-mini"
))
```

The official preset selects `OpenAIAPIDialect.responses`. For a standard Chat Completions endpoint, use `.openAIChatCompletions(...)` or an explicit configuration with `dialect: .chatCompletions`.
