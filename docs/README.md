# omllm Documentation

- [Architecture](architecture.md): core abstractions and provider boundaries.
- [Requests and Attachments](requests.md): direct request values, the optional builder DSL, and images/documents.
- [Providers](providers.md): OpenAI-compatible dialects, Anthropic, presets, and immutable configuration.
- [Streaming and Models](streaming-and-models.md): semantic streaming events and model catalog access.
- [Migration](migration.md): moving from the removed standalone OpenAI module.

The package is a multi-provider chat inference SDK. It does not provide provider file storage, batches, assistants, hosted tools, or other provider-platform infrastructure APIs.
