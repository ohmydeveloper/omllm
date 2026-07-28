// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "omllm",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "LLMCore", targets: ["LLMCore"]),
        .library(name: "LLMAnthropic", targets: ["LLMAnthropic"]),
        .library(name: "LLMOpenAICompatible", targets: ["LLMOpenAICompatible"]),
        .library(name: "LLMTestSupport", targets: ["LLMTestSupport"]),
    ],
    targets: [
        .target(name: "LLMCore"),
        .target(name: "LLMAnthropic", dependencies: ["LLMCore"]),
        .target(name: "LLMOpenAICompatible", dependencies: ["LLMCore"]),
        .target(name: "LLMTestSupport", dependencies: ["LLMCore"]),
        .testTarget(
            name: "LLMCoreTests",
            dependencies: ["LLMCore", "LLMTestSupport", "LLMAnthropic", "LLMOpenAICompatible"]
        ),
        .testTarget(name: "LLMAnthropicTests", dependencies: ["LLMCore", "LLMAnthropic"]),
        .testTarget(
            name: "LLMOpenAICompatibleTests",
            dependencies: ["LLMCore", "LLMOpenAICompatible"]
        ),
        .testTarget(
            name: "LLMIntegrationTests",
            dependencies: ["LLMCore", "LLMOpenAICompatible", "LLMTestSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
