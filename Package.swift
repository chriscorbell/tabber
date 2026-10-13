// swift-tools-version: 6.0
import PackageDescription

let llamaRelease = "b11577"

let package = Package(
    name: "Tabber",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TabberKit", targets: ["TabberApp"]),
        .executable(name: "tabber-bench", targets: ["tabber-bench"]),
        .executable(name: "tabber-probe", targets: ["tabber-probe"]),
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/\(llamaRelease)/llama-\(llamaRelease)-xcframework.zip",
            checksum: "8b2af91c7a1ffe2b3635ed5241bc30f216e64fa6abc15a6f2cbd2ccaaf8813c0"
        ),

        // Pure logic: models, session state machine, text rules, prompt building. No AppKit.
        .target(name: "TabberCore"),

        // llama.cpp wrapper: model loading, KV reuse, constrained decoding.
        .target(name: "TabberEngine", dependencies: ["TabberCore", "llama"]),

        // Accessibility: focus tracking and reading the focused text field.
        .target(name: "TabberAX", dependencies: ["TabberCore"]),

        // Keyboard: event tap and synthetic text insertion.
        .target(name: "TabberInput", dependencies: ["TabberCore"]),

        // Ghost text and mirror windows.
        .target(name: "TabberOverlay", dependencies: ["TabberCore"]),

        // Extra context: on-screen text (OCR) and clipboard.
        .target(name: "TabberContext", dependencies: ["TabberCore"]),

        // The app: coordinator, menu bar, settings, onboarding.
        .target(
            name: "TabberApp",
            dependencies: ["TabberCore", "TabberEngine", "TabberAX", "TabberInput", "TabberOverlay", "TabberContext"]
        ),

        // Command-line harness for measuring completion quality and latency.
        .executableTarget(name: "tabber-bench", dependencies: ["TabberCore", "TabberEngine"]),

        // Manual probe for live checks of the AX, input and overlay layers.
        .executableTarget(name: "tabber-probe", dependencies: ["TabberCore", "TabberAX", "TabberInput", "TabberOverlay", "TabberContext"]),

        .testTarget(name: "TabberCoreTests", dependencies: ["TabberCore"]),
        .testTarget(name: "TabberEngineTests", dependencies: ["TabberEngine"]),
        .testTarget(name: "TabberAXTests", dependencies: ["TabberAX"]),
        .testTarget(name: "TabberInputTests", dependencies: ["TabberInput"]),
        .testTarget(name: "TabberOverlayTests", dependencies: ["TabberOverlay"]),
        .testTarget(name: "TabberContextTests", dependencies: ["TabberContext"]),
    ],
    swiftLanguageModes: [.v5]
)
