import Foundation
import Testing

@testable import PTTAudio
@testable import PTTSettings
@testable import PTTWhisper

/// End-to-end check of the real inference path.
///
/// Skipped unless the model has been downloaded and the whisper.cpp submodule's sample is
/// present, so a fresh clone still passes `swift test` without a 141 MB download.
@Suite("Whisper engine")
struct WhisperEngineTests {

    private static var jfkSample: URL? {
        // Tests run from the package root's build directory; walk up to the checkout.
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PushToTypeTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Vendor/whisper.cpp/samples/jfk.wav")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    @Test("Transcribes the whisper.cpp sample")
    func transcribesSample() async throws {
        try #require(WhisperModel.baseEn.isDownloaded, "run the app once to fetch base.en")
        let sample = try #require(Self.jfkSample, "git submodule update --init")

        let engine = WhisperEngine()
        try await engine.load(.baseEn)

        let audio = try AudioFileLoader.samples(from: sample)
        #expect(audio.count > Int(WhisperEngine.requiredSampleRate))

        let result = try await engine.transcribe(samples: audio, language: .english)
        let text = result.text.lowercased()

        #expect(text.contains("ask not"))
        #expect(text.contains("country"))
        #expect(result.duration > 0)

        await engine.unload()
        let unloaded = await engine.currentModel
        #expect(unloaded == nil)
    }

    @Test("Rejects audio that is too short to be speech")
    func rejectsTinyInput() async throws {
        try #require(WhisperModel.baseEn.isDownloaded, "run the app once to fetch base.en")

        let engine = WhisperEngine()
        try await engine.load(.baseEn)

        await #expect(throws: PTTError.emptyRecording) {
            _ = try await engine.transcribe(samples: [Float](repeating: 0, count: 64), language: .english)
        }
        await engine.unload()
    }

    @Test("Transcribing without a model is an error, not a crash")
    func failsWithoutModel() async {
        let engine = WhisperEngine()
        let audio = [Float](repeating: 0.01, count: 16_000)
        await #expect(throws: (any Error).self) {
            _ = try await engine.transcribe(samples: audio, language: .english)
        }
    }
}
