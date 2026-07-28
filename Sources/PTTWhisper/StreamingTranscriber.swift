import Foundation
import PTTSettings
import PTTSupport

/// Transcribes an utterance *while it is still being spoken*, so that releasing the key
/// costs only the leftover tail.
///
/// ## Why this exists
/// A five-second dictation takes roughly a second of CPU on `base.en`. Doing that work
/// after the key comes up is a second of visible waiting. Instead, audio is cut at natural
/// pauses and each finished chunk is transcribed during the hold; on release only the
/// samples since the last cut remain, so perceived latency is bounded by the length of the
/// last phrase rather than the whole utterance.
///
/// ## Why chunks are cut at silence
/// Cutting mid-word truncates the acoustic context whisper needs and produces mangled word
/// boundaries. A cut is therefore only made where the signal has been quiet for
/// ``Configuration/silenceSeconds``; if the speaker never pauses, a hard limit at
/// ``Configuration/maximumChunkSeconds`` applies, which is long enough that the damage is
/// confined to one word boundary.
///
/// ## Ordering
/// Each chunk's task awaits its predecessor before calling the engine. That serialises the
/// passes (the engine would serialise them anyway), preserves output order, and lets every
/// chunk use the previous text as whisper's initial prompt so punctuation and casing stay
/// consistent across the seam.
public actor StreamingTranscriber {

    public struct Configuration: Sendable {
        /// Shortest committed chunk. Below this, whisper has too little context.
        public var minimumChunkSeconds: Double
        /// Forced cut point when the speaker never pauses.
        public var maximumChunkSeconds: Double
        /// Quiet time that marks a safe cut.
        public var silenceSeconds: Double

        public init(
            minimumChunkSeconds: Double = 2.0,
            maximumChunkSeconds: Double = 12.0,
            silenceSeconds: Double = 0.35
        ) {
            self.minimumChunkSeconds = minimumChunkSeconds
            self.maximumChunkSeconds = maximumChunkSeconds
            self.silenceSeconds = silenceSeconds
        }

        public static let `default` = Configuration()
    }

    private let engine: WhisperEngine
    private let language: Language
    private let configuration: Configuration
    private let sampleRate: Double

    /// Samples not yet handed to a chunk task.
    private var pending: [Float] = []
    /// One task per committed chunk, in order. Each awaits the previous one.
    private var chunkTasks: [Task<String, Error>] = []
    /// `true` once `finish()` or `cancel()` has run, to reject late `append` calls.
    private var isClosed = false

    public init(
        engine: WhisperEngine,
        language: Language,
        configuration: Configuration = .default,
        sampleRate: Double = WhisperEngine.requiredSampleRate
    ) {
        self.engine = engine
        self.language = language
        self.configuration = configuration
        self.sampleRate = sampleRate
        pending.reserveCapacity(Int(sampleRate * configuration.maximumChunkSeconds))
    }

    /// Feeds newly captured audio. Cheap: it appends and, at most, starts one chunk task.
    public func append(_ samples: [Float]) {
        guard !isClosed else { return }
        pending.append(contentsOf: samples)
        commitIfReady()
    }

    /// Ends the utterance and returns the complete transcript.
    ///
    /// - Throws: whatever the engine threw for the *first* failing chunk, or
    ///           `CancellationError` if the dictation was abandoned.
    public func finish() async throws -> String {
        isClosed = true

        // The tail goes through the same path as every other chunk so there is exactly one
        // inference code path, prompts included.
        if !pending.isEmpty {
            commit(Array(pending))
            pending.removeAll(keepingCapacity: false)
        }

        var pieces: [String] = []
        pieces.reserveCapacity(chunkTasks.count)
        for task in chunkTasks {
            do {
                pieces.append(try await task.value)
            } catch let error as PTTError where error == .emptyRecording {
                // A chunk that turned out to be pure silence is not a failure of the
                // utterance — it just contributes nothing.
                continue
            }
        }
        chunkTasks.removeAll()

        return TranscriptPostProcessor.join(pieces)
    }

    /// Abandons the utterance and stops any inference already under way.
    public func cancel() {
        isClosed = true
        for task in chunkTasks { task.cancel() }
        chunkTasks.removeAll()
        pending.removeAll(keepingCapacity: false)
    }

    // MARK: - Chunking

    /// Commits `pending` when it is long enough *and* ends in a pause, or when it has hit
    /// the hard length limit.
    private func commitIfReady() {
        let duration = Double(pending.count) / sampleRate
        guard duration >= configuration.minimumChunkSeconds else { return }

        if duration >= configuration.maximumChunkSeconds {
            commit(Array(pending))
            pending.removeAll(keepingCapacity: true)
            return
        }

        guard VoiceActivity.endsWithSilence(
            pending,
            sampleRate: sampleRate,
            seconds: configuration.silenceSeconds
        ) else { return }

        // The trailing silence stays inside the committed chunk: whisper reads it as an
        // end-of-speech cue, and trimming it makes the final word more likely to be
        // clipped.
        commit(Array(pending))
        pending.removeAll(keepingCapacity: true)
    }

    /// Starts inference for one chunk, chained behind the previous one.
    private func commit(_ samples: [Float]) {
        let previous = chunkTasks.last
        let engine = self.engine
        let language = self.language

        chunkTasks.append(
            Task {
                // Chain: the prompt is whatever came before, and awaiting it also keeps
                // the output in order.
                let prompt = try? await previous?.value
                try Task.checkCancellation()
                let result = try await engine.transcribe(
                    samples: samples,
                    language: language,
                    initialPrompt: prompt
                )
                return result.text
            }
        )
    }
}
