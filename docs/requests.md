# Requests And Attachments

`LLMRequest` is the canonical input value. Direct construction is the normal, first-class API:

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

Messages preserve content ordering. In the preceding request, text is sent before the image, which is sent before the document.

## Optional Builder DSL

The builder is a convenience for static multi-part messages. It produces the same canonical values as direct construction:

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

Builder blocks support `if` and `for` control flow:

```swift
let request = try LLMRequest.build {
    LLMRequestComponent.user {
        for caption in captions {
            LLMContent.textContent(caption)
        }
        if includeDocument {
            LLMContent.document(data: pdfData, mediaType: "application/pdf")
        }
    }
}
```

The throwing build validates only local structure:

- duplicate model, instructions, or options components;
- no messages or an empty message;
- empty text or attachment bytes;
- invalid image/document metadata;
- invalid temperature, top-p, or maximum output token values.

It does not validate provider or model capabilities. That is driver responsibility because the builder has no active provider context.

## Attachments

Images and documents are normal chat content, not remote provider files. Both preserve their original source:

```swift
let image = LLMContent.image(data: imageData, mediaType: "image/jpeg")
let remoteImage = LLMContent.image(url: imageURL, mediaType: "image/jpeg")
let pdf = LLMContent.document(data: pdfData, mediaType: "application/pdf", filename: "report.pdf")
let remotePDF = LLMContent.document(url: pdfURL, mediaType: "application/pdf")
```

PDF is a supported common document format. Provider/dialect/model attachment support varies. Drivers never silently drop an attachment; unsupported inputs fail with `LLMError.unsupportedFeature` before transport.
