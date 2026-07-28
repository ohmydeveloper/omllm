import Foundation
import LLMAnthropic
import LLMCore
import LLMOpenAICompatible
import Testing

@Suite("Request builders")
struct LLMRequestBuilderTests {
    @Test("builder produces the same canonical request as direct construction")
    func builderMatchesDirectConstruction() throws {
        let imageData = Data([1, 2, 3])
        let documentURL = try #require(URL(string: "https://example.com/guide.pdf"))
        let built = try LLMRequest.build {
            LLMRequestComponent.model("model-a")
            LLMRequestComponent.instructions("Answer briefly")
            LLMRequestComponent.options(.init(temperature: 0.2, maxOutputTokens: 100))
            LLMRequestComponent.user {
                LLMContent.textContent("Describe these files.")
                LLMContent.image(data: imageData, mediaType: "image/png")
                LLMContent.document(url: documentURL, mediaType: "application/pdf", filename: "guide.pdf")
            }
            LLMRequestComponent.assistant {
                LLMContent.textContent("I can help.")
            }
        }

        let expected = LLMRequest(
            model: "model-a",
            instructions: "Answer briefly",
            messages: [
                .init(role: .user, content: [
                    .text("Describe these files."),
                    .image(.init(data: imageData, mediaType: "image/png")),
                    .document(.init(url: documentURL, mediaType: "application/pdf", filename: "guide.pdf")),
                ]),
                .assistant("I can help."),
            ],
            options: .init(temperature: 0.2, maxOutputTokens: 100)
        )
        #expect(built == expected)
    }

    @Test("builder supports conditional and looped message content")
    func builderControlFlow() throws {
        let includeDocument = true
        let labels = ["first", "second"]
        let request = try LLMRequest.build {
            LLMRequestComponent.user {
                for label in labels {
                    LLMContent.textContent(label)
                }
                if includeDocument {
                    LLMContent.document(data: Data([37, 80, 68, 70]), mediaType: "application/pdf", filename: "page.pdf")
                }
            }
        }

        #expect(request.messages[0].content == [
            .text("first"),
            .text("second"),
            .document(.init(data: Data([37, 80, 68, 70]), mediaType: "application/pdf", filename: "page.pdf")),
        ])
    }

    @Test("builder preserves Data and URL attachment sources")
    func attachmentSources() throws {
        let imageURL = try #require(URL(string: "https://example.com/image.jpg"))
        let request = try LLMRequest.build {
            LLMRequestComponent.user {
                LLMContent.image(url: imageURL, mediaType: "image/jpeg")
                LLMContent.document(data: Data([1]), mediaType: "application/pdf")
            }
        }

        guard case let .image(image) = request.messages[0].content[0],
              case let .document(document) = request.messages[0].content[1] else {
            Issue.record("Expected image then document")
            return
        }
        #expect(image.url == imageURL)
        #expect(image.data == nil)
        #expect(document.data == Data([1]))
        #expect(document.url == nil)
    }

    @Test("builder rejects deterministic structural errors")
    func validationErrors() {
        #expect(throws: LLMError.invalidRequest("Request builder received more than one model")) {
            try LLMRequest.build { LLMRequestComponent.model("a"); LLMRequestComponent.model("b"); LLMRequestComponent.user { LLMContent.textContent("Hi") } }
        }
        #expect(throws: LLMError.invalidRequest("A message must contain content")) {
            try LLMRequest.build { LLMRequestComponent.user {} }
        }
        #expect(throws: LLMError.invalidRequest("Temperature must be between 0 and 2")) {
            try LLMRequest.build { LLMRequestComponent.temperature(3); LLMRequestComponent.user { LLMContent.textContent("Hi") } }
        }
        #expect(throws: LLMError.invalidRequest("Image media type is invalid")) {
            try LLMRequest.build { LLMRequestComponent.user { LLMContent.image(data: Data([1]), mediaType: "application/pdf") } }
        }
    }

    @Test("provider configurations return modified copies")
    func fluentConfigurationCopies() {
        let compatible = OpenAICompatibleConfiguration.openAI(apiKey: "key")
        let changedCompatible = compatible
            .withDefaultModel("gpt-4.1-mini")
            .withTimeout(10)
            .withHeader("X-App", value: "example")
        #expect(compatible.defaultModel == nil)
        #expect(compatible.timeout == 60)
        #expect(compatible.additionalHeaders.isEmpty)
        #expect(changedCompatible.defaultModel == "gpt-4.1-mini")
        #expect(changedCompatible.timeout == 10)
        #expect(changedCompatible.additionalHeaders["X-App"] == "example")
        #expect(changedCompatible.dialect == .responses)

        let anthropic = AnthropicConfiguration(apiKey: "key")
        let changedAnthropic = anthropic
            .withDefaultModel("claude-sonnet")
            .withTimeout(15)
            .withHeader("X-App", value: "example")
            .withBetaFeatures(["feature"])
        #expect(anthropic.defaultModel == nil)
        #expect(anthropic.timeout == 60)
        #expect(anthropic.additionalHeaders.isEmpty)
        #expect(anthropic.betaFeatures.isEmpty)
        #expect(changedAnthropic.defaultModel == "claude-sonnet")
        #expect(changedAnthropic.timeout == 15)
        #expect(changedAnthropic.additionalHeaders["X-App"] == "example")
        #expect(changedAnthropic.betaFeatures == ["feature"])
    }
}
