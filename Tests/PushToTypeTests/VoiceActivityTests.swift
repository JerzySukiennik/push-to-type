import Foundation
import Testing

@testable import PTTSupport

@Suite("Voice activity")
struct VoiceActivityTests {

    private let sampleRate: Double = 16_000

    /// A sine burst loud enough to count as speech.
    private func tone(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { index in
            amplitude * sin(Float(index) * 0.1)
        }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(sampleRate * seconds))
    }

    @Test("Digital silence is silent")
    func detectsSilence() {
        #expect(VoiceActivity.isSilent(silence(seconds: 0.5)[...]))
        #expect(!VoiceActivity.containsSpeech(silence(seconds: 2), sampleRate: sampleRate))
    }

    @Test("A short burst inside a long silence still counts as speech")
    func findsShortUtterance() {
        let samples = silence(seconds: 1.5) + tone(seconds: 0.2) + silence(seconds: 1.5)
        // The overall RMS here is far below the threshold, which is exactly why the check
        // is windowed rather than global.
        #expect(VoiceActivity.rms(samples[...]) < VoiceActivity.silenceThreshold)
        #expect(VoiceActivity.containsSpeech(samples, sampleRate: sampleRate))
    }

    @Test("A trailing pause is a safe cut point")
    func detectsTrailingSilence() {
        let spoken = tone(seconds: 1.0)
        #expect(!VoiceActivity.endsWithSilence(spoken, sampleRate: sampleRate, seconds: 0.35))
        #expect(
            VoiceActivity.endsWithSilence(
                spoken + silence(seconds: 0.5),
                sampleRate: sampleRate,
                seconds: 0.35
            )
        )
        // Not enough quiet yet: the speaker may only be between words.
        #expect(
            !VoiceActivity.endsWithSilence(
                spoken + silence(seconds: 0.1),
                sampleRate: sampleRate,
                seconds: 0.35
            )
        )
    }

    @Test("Peak tracks the loudest sample")
    func measuresPeak() {
        let samples: [Float] = [0.1, -0.8, 0.2]
        #expect(abs(VoiceActivity.peak(samples[...]) - 0.8) < 0.0001)
        #expect(VoiceActivity.peak([][...]) == 0)
    }
}
