// swift-tools-version: 6.0
//
// PushToType — hold a key, speak, release, get text.
//
// The package builds a plain executable; Scripts/build-app.sh wraps it into a real
// .app bundle (Info.plist + icon + ad-hoc signature). Building this way keeps the
// project usable with only the Command Line Tools installed, while remaining a
// standard SwiftPM package that Xcode can open unchanged.
//
// Before the first build run:
//   git submodule update --init --recursive
//   ./Scripts/build-whisper.sh

import PackageDescription

/// Static libraries produced by Scripts/build-whisper.sh, in dependency order.
/// Paths are relative to the package root, which is the working directory `swift build`
/// runs in.
let whisperLinkerFlags: [String] = [
    "-L.build/whisper/lib",
    "-lwhisper",
    "-lggml",
    "-lggml-cpu",
    "-lggml-blas",
    "-lggml-base",
]

let package = Package(
    name: "PushToType",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PushToType", targets: ["PushToType"]),
        .executable(name: "ptt-doctor", targets: ["PTTDoctor"]),
    ],
    targets: [

        // MARK: C interop

        /// Module map over the statically linked whisper.cpp headers.
        .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),

        // MARK: Leaves

        /// Logging, the shared error type, filesystem locations, small primitives.
        .target(name: "PTTSupport"),

        /// User preferences, the hotkey value type, the model and language catalogs.
        .target(name: "PTTSettings", dependencies: ["PTTSupport"]),

        // MARK: Capability modules

        /// Microphone capture, resampling and voice-activity detection.
        .target(name: "PTTAudio", dependencies: ["PTTSupport", "PTTSettings"]),

        /// Model management and whisper.cpp inference.
        .target(
            name: "PTTWhisper",
            dependencies: ["PTTSupport", "PTTSettings", "CWhisper"]
        ),

        /// The global press-and-hold hotkey.
        .target(name: "PTTHotkeys", dependencies: ["PTTSupport", "PTTSettings"]),

        /// Delivering the transcript to the focused text field.
        .target(name: "PTTInsertion", dependencies: ["PTTSupport", "PTTSettings"]),

        /// Optional, opt-in refinement of the transcript by a language model (Gemini).
        .target(name: "PTTRefine", dependencies: ["PTTSupport", "PTTSettings"]),

        /// Menu bar item, HUD panel, settings window, onboarding.
        .target(
            name: "PTTUI",
            dependencies: [
                "PTTSupport", "PTTSettings", "PTTAudio", "PTTWhisper", "PTTHotkeys", "PTTRefine",
            ]
        ),

        // MARK: Application

        /// Composition root: wires the modules together and owns the state machine.
        .executableTarget(
            name: "PushToType",
            dependencies: [
                "PTTSupport", "PTTSettings", "PTTAudio",
                "PTTWhisper", "PTTHotkeys", "PTTInsertion", "PTTUI", "PTTRefine",
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .unsafeFlags(whisperLinkerFlags),
            ]
        ),

        /// Command-line diagnostics: verifies the model, the engine, the audio device and
        /// the permissions on a real machine. Complements the unit tests, which cover pure
        /// logic; this covers everything that can only fail in situ.
        .executableTarget(
            name: "PTTDoctor",
            dependencies: ["PTTSupport", "PTTSettings", "PTTAudio", "PTTWhisper", "PTTInsertion"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .unsafeFlags(whisperLinkerFlags),
            ]
        ),

        // MARK: Tests

        .testTarget(
            name: "PushToTypeTests",
            dependencies: [
                "PTTSupport", "PTTSettings", "PTTAudio", "PTTInsertion", "PTTWhisper",
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .unsafeFlags(whisperLinkerFlags),
            ]
        ),
    ]
)
