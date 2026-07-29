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
    /// −52 dBFS. The gate exists for one purpose: stopping whisper from inventing "Thank
    /// you." out of an empty room. It is not a quality filter, so it errs low — a built-in
    /// laptop microphone at arm's length produces surprisingly little signal, and rejecting
    /// real speech is a far worse failure than passing room tone to a model that has its
    /// own no-speech detection.
    public static let silenceThreshold: Float = 0.0025

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
    /// - Parameter threshold: what counts as quiet *here*. This is deliberately not
    ///   ``silenceThreshold``, because the two questions want opposite biases. "Was
    ///   anything recorded?" should err towards yes, so its threshold sits near the noise
    ///   floor. "Has the speaker paused?" compares against the speech in this very
    ///   utterance: room tone in a quiet study and room tone next to a fan differ by more
    ///   than the gap between silence and speech, so an absolute constant finds pauses in
    ///   one room and none at all in the other. Callers pass a level derived from how loud
    ///   this speaker actually is — see ``pauseThreshold(forSpeechLevel:)``.
    ///
    /// Scans backwards in short windows and stops at the first one that is not quiet, so
    /// the cost is proportional to the silence examined, not to the length of the buffer.
    public static func endsWithSilence(
        _ samples: [Float],
        sampleRate: Double,
        seconds: Double,
        threshold: Float = silenceThreshold
    ) -> Bool {
        let required = Int(sampleRate * seconds)
        guard required > 0, samples.count > required else { return false }

        let window = max(1, Int(sampleRate * 0.02))
        var cursor = samples.endIndex
        while cursor > samples.startIndex {
            let start = max(samples.startIndex, cursor - window)
            if rms(samples[start..<cursor]) >= threshold { break }
            if samples.endIndex - start >= required { return true }
            cursor = start
        }
        return false
    }

    /// The level below which this speaker counts as having paused.
    ///
    /// A twelfth of their own speech level — about −22 dB relative — which is far below
    /// any vowel and comfortably above the room tone that sits underneath it. Floored at
    /// ``silenceThreshold`` so a near-silent recording cannot drive the threshold to zero
    /// and declare the whole thing a pause.
    public static func pauseThreshold(forSpeechLevel level: Float) -> Float {
        max(silenceThreshold, level * 0.08)
    }
}
