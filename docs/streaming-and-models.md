# Streaming And Models

## Model Catalogs

Use the provider-neutral client to list models:

```swift
let models = try await client.listModels()
for model in models {
    print(model.model.id, model.displayName ?? "")
}
```

OpenAI-style endpoints use the configured models path, which defaults to `GET /models`. Anthropic follows its paginated catalog until all available pages are retrieved. A configured endpoint that cannot list models reports `LLMError.unsupportedFeature`.

## Streaming

Drivers convert provider SSE records into semantic `LLMEvent` values:

```swift
for try await event in client.stream(.text("Write one sentence.")) {
    switch event {
    case let .textDelta(text):
        print(text, terminator: "")
    case let .toolCallStarted(id, name):
        print("\nTool: \(name) (\(id))")
    case let .toolCallArgumentsDelta(_, fragment):
        print(fragment, terminator: "")
    case let .usage(usage):
        print("\nTokens: \(usage.totalTokens ?? 0)")
    case let .completed(response):
        print("\nFinished: \(response.finishReason)")
    default:
        break
    }
}
```

The shared SSE parser handles arbitrary byte boundaries, comments, CRLF/LF delimiters, multiline data, and terminal records. Provider drivers own their event-name and payload mapping; application code only handles canonical events.
