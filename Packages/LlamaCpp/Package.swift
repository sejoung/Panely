// swift-tools-version:5.9
import PackageDescription

// llama.cpp's own prebuilt XCFramework (Metal, Accelerate), pinned to one
// release by URL and checksum. It runs the translation model (Gemma 4 E2B,
// GGUF) inside the app — see `GemmaTranslator`.
//
// To update: pick a release from https://github.com/ggml-org/llama.cpp/releases,
// then `swift package compute-checksum llama-<tag>-xcframework.zip`.
let package = Package(
    name: "LlamaCpp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LlamaCpp", targets: ["llama"]),
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11819/llama-b11819-xcframework.zip",
            checksum: "967a7fd337642d8bbae09a7e8463bf722abf55e75c0676fcab8b6a7ba3471827"
        ),
    ]
)
