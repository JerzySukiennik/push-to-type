import Accelerate
import Foundation

/// Cheap amplitude analysis shared by capture and streaming inference.
///
/// Lives in `PTTSupport` because two modules need it for different reasons: `PTTAudio`
/// decides whether a recording was silent, `PTTWhisper` uses it to find safe places to cut
/// a long utterance into chunks. Everything here is `vDSP`-backed and allocation-free, so
/// it can run on every 100 ms buffer without showing up in a CPU sample.
public enum VoiceActivity {

    /// Amplitude below which a frame counts as silence.
    ///
    /// −45 dBFS: quiet enough to ignore fan noise and a laptop keyboard, loud enough that
    /// a whisper (the human kind) still registers.
    public static let silenceThreshold: Float = 0.0056

    /// Root-mean-square amplitude of `samples`.
    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard let base = samples.baseAddress, !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(base, 1, &value, vDSP_Length(samples.count))
        return value
    }

    /// Root-mean-square amplitude of a slice.
    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        samples.withUnsafeBufferPointer { rms($0) }
    }

    /// Peak absolute amplitude, used for the HUD level meter.
    public static func peak(_ samples: ArraySlice<Float>) -> Float {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return 0 }
            var value: Float = 0
            vDSP_maxmgv(base, 1, &value, vDSP_Length(buffer.count))
            return value
        }
    }

    /// `true` when the whole slice sits below the silence threshold.
    public static func isSilent(_ samples: ArraySlice<Float>) -> Bool {
        rms(samples) < silenceThreshold
    }

    /// `true` when the recording contains no passage loud enough to be speech.
    ///
    /// Judged on short windows rather than on the whole buffer, so a single word inside
    /// three seconds of silence still counts as speech — the average would not.
    public static func containsSpeech(
        _ samples: [Float],
        sampleRate: Double,
        windowSeconds: Double = 0.05
    ) -> Bool {
        let window = max(1, Int(sampleRate * windowSeconds))
        var index = samples.startIndex
        while index < samples.endIndex {
            let end = min(index + window, samples.endIndex)
            if rms(samples[index..<end]) >= silenceThreshold { return true }
            index = end
        }
        return false
    }

    /// `true` when the last `seconds` of `samples` are quiet — i.e. the speaker has
    /// paused and the buffer can be cut here without slicing through a word.
    ///
    /// Scans backwards in short windows and stops at the first one that is not silent, so
    /// the cost is proportional to the silence examined, not to the length of the buffer.
    public static func endsWithSilence(
        _ samples: [Float],
        sampleRate: Double,
        seconds: Double
    ) -> Bool {
        let required = Int(sampleRate * seconds)
        guard required > 0, samples.count > required else { return false }

        let window = max(1, Int(sampleRate * 0.02))
        var cursor = samples.endIndex
        while cursor > samples.startIndex {
            let start = max(samples.startIndex, cursor - window)
            if rms(samples[start..<cursor]) >= silenceThreshold { break }
            if samples.endIndex - start >= required { return true }
            cursor = start
        }
        return false
    }
}
