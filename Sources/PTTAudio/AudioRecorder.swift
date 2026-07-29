import AVFoundation
import Foundation
import PTTSupport

/// Captures microphone audio as 16 kHz mono float samples — the only format whisper accepts.
///
/// ## Idle cost
/// `AVAudioEngine` and its converter are created in ``start(onChunk:)`` and destroyed in
/// ``stop()``. Keeping a started engine around would hold the audio HAL open, spin a
/// render thread, and leave the orange microphone indicator lit while the app is doing
/// nothing — all three unacceptable for a background utility.
///
/// ## Threading
/// The input tap is called on a high-priority audio thread that must never block. It
/// therefore writes into a lock-guarded ``CaptureBuffer`` and calls the caller's chunk
/// handler directly; it never touches the actor, because hopping to an actor from the
/// render thread would risk priority inversion and drop-outs.
public actor AudioRecorder {

    /// Delivered for every converted buffer (~100 ms) while recording.
    public typealias ChunkHandler = @Sendable ([Float]) -> Void

    /// Called once if a dictation runs to its ceiling.
    public typealias LimitHandler = @Sendable () -> Void

    /// Ceiling when the audio has to be kept — streaming off, so the whole recording is
    /// transcribed in one pass at the end and every sample must still be in memory.
    ///
    /// 16 kHz mono float is 3.8 MB per minute, so five minutes costs 19 MB while recording
    /// and nothing once it ends.
    public static let retainedAudioLimit: TimeInterval = 300

    /// Ceiling when the audio does *not* have to be kept — streaming on.
    ///
    /// Nothing accumulates here, so this is not a memory limit; it is a backstop against a
    /// key that never comes up. An hour is far past any dictation a person actually gives,
    /// which is the point: the user should never meet it, and the app should still not
    /// record forever if something goes wrong.
    public static let streamingLimit: TimeInterval = 3600


    private var engine: AVAudioEngine?
    private var buffer: CaptureBuffer?

    public init() {}

    /// `true` between `start` and `stop`.
    public var isRecording: Bool { engine != nil }

    // MARK: - Capture

    /// Starts capturing.
    ///
    /// - Parameter onChunk: called on the audio thread with each converted buffer. Keep it
    ///   short: no allocation-heavy work, no locks that a slower thread might hold.
    /// - Throws: ``PTTError/microphoneDenied`` or ``PTTError/audioEngineFailed(reason:)``.
    /// - Parameter onLimitReached: called once, on the audio thread, the moment the
    ///   recording reaches whichever ceiling currently applies. The caller is expected to end the dictation
    ///   and keep what was captured.
    public func start(
        onChunk: @escaping ChunkHandler,
        onLimitReached: @escaping LimitHandler = {}
    ) async throws {
        guard engine == nil else { return }

        try await MicrophonePermission.require()
        guard MicrophonePermission.hasInputDevice else {
            throw PTTError.audioEngineFailed(reason: "no audio input device is available")
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw PTTError.audioEngineFailed(reason: "the input device reported an empty format")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: WhisperSampleRate.value,
            channels: 1,
            interleaved: false
        ) else {
            throw PTTError.audioEngineFailed(reason: "could not create the 16 kHz output format")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw PTTError.audioEngineFailed(
                reason: "cannot convert from \(Int(inputFormat.sampleRate)) Hz"
            )
        }
        // Whisper is trained on band-limited speech; mastering-grade resampling would cost
        // CPU that changes nothing about the transcript.
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue

        let capture = CaptureBuffer(
            retainLimit: Int(WhisperSampleRate.value * Self.retainedAudioLimit),
            hardLimit: Int(WhisperSampleRate.value * Self.streamingLimit),
            sampleRate: WhisperSampleRate.value
        )
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate

        // ~100 ms of input per callback: small enough that the streaming transcriber sees
        // pauses promptly, large enough that the conversion overhead stays invisible.
        let tapFrames = AVAudioFrameCount(inputFormat.sampleRate / 10)

        input.installTap(onBus: 0, bufferSize: tapFrames, format: inputFormat) {
            [converter, targetFormat, capture] inputBuffer, _ in

            let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 64
            guard let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: capacity
            ) else { return }

            // The converter asks for input until it is told there is no more, so the
            // buffer is handed over exactly once. Both the flag and the buffer travel in
            // boxes: `AVAudioConverterInputBlock` is declared `@Sendable`, but it is in
            // fact invoked synchronously on this very thread before `convert` returns, so
            // nothing actually crosses a concurrency boundary here.
            let pending = CallLocal(inputBuffer)
            let consumed = CallLocal(false)
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                if consumed.value {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed.value = true
                outStatus.pointee = .haveData
                return pending.value
            }

            guard status != .error, output.frameLength > 0,
                  let channel = output.floatChannelData?[0]
            else {
                if let conversionError {
                    Log.audio.error("Conversion failed: \(conversionError.localizedDescription)")
                }
                return
            }

            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            let reachedLimit = capture.append(samples)
            onChunk(samples)
            if reachedLimit { onLimitReached() }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw PTTError.audioEngineFailed(reason: error.localizedDescription)
        }

        self.engine = engine
        self.buffer = capture
        Log.audio.debug("Recording started at \(inputFormat.sampleRate, format: .fixed(precision: 0)) Hz")
    }

    /// Stops keeping a copy of the audio.
    ///
    /// Called once the streaming transcriber owns everything recorded so far, which is the
    /// point at which a second copy in memory buys nothing. After this the recording can
    /// run as long as the speaker likes: only statistics accumulate, at a few bytes a
    /// minute.
    public func releaseRetainedAudio() {
        buffer?.stopRetaining()
        Log.audio.debug("Retention released; recording is now unbounded")
    }

    /// Stops capturing and reports what was recorded.
    ///
    /// ``RecordingSummary/samples`` is empty when retention was released — by then the
    /// transcriber holds the audio, and the summary's statistics are what the caller
    /// actually needs.
    @discardableResult
    public func stop() -> RecordingSummary {
        guard let engine else {
            return RecordingSummary(samples: [], duration: 0, peak: 0, containsSpeech: false)
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Dropping the reference releases the audio unit, which is what actually turns the
        // microphone indicator off.
        self.engine = nil

        let summary = buffer?.summary()
            ?? RecordingSummary(samples: [], duration: 0, peak: 0, containsSpeech: false)
        buffer = nil
        Log.audio.debug(
            "Recording stopped: \(summary.duration, format: .fixed(precision: 2)) s"
        )
        return summary
    }

    /// Stops without returning audio — used when a dictation is abandoned.
    public func abort() {
        _ = stop()
    }
}

/// Sample rate whisper.cpp requires, kept here so `PTTAudio` does not depend on
/// `PTTWhisper` just to read a constant.
enum WhisperSampleRate {
    static let value: Double = 16_000
}

/// What a finished recording amounted to.
///
/// The audio itself is optional because it is usually not needed: once the streaming
/// transcriber has taken over, every sample has already been handed to it, and keeping a
/// second copy is what put a ceiling on how long a dictation could be.
public struct RecordingSummary: Sendable {
    /// The captured audio, or empty once retention was released.
    public let samples: [Float]
    /// How long the microphone was open.
    public let duration: TimeInterval
    /// Loudest sample seen.
    public let peak: Float
    /// Whether any window was loud enough to be speech.
    ///
    /// Computed as the audio arrives rather than from ``samples``, so the answer stays
    /// correct for recordings that were never kept.
    public let containsSpeech: Bool
}

/// Accumulates audio written from the audio thread, and the statistics that outlive it.
///
/// A plain lock rather than an actor: the render thread cannot `await`, and the critical
/// section is a single `append` of a few hundred floats — orders of magnitude shorter than
/// the buffer interval, so contention never approaches a drop-out.
///
/// Retention is a phase, not a setting. Every dictation starts by keeping its audio,
/// because until the model has finished loading there is no transcriber to give it to. The
/// moment one exists and has been handed the backlog, ``stopRetaining()`` drops the copy
/// and the recording stops growing in memory — which is what makes an unbounded dictation
/// possible at all.
private final class CaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []

    private let retainLimit: Int
    private let hardLimit: Int
    private var retains = true
    private var reportedLimit = false

    private var frameCount = 0
    private var peak: Float = 0
    private var speechDetected = false
    private let sampleRate: Double

    init(retainLimit: Int, hardLimit: Int, sampleRate: Double) {
        self.retainLimit = retainLimit
        self.hardLimit = hardLimit
        self.sampleRate = sampleRate
        storage.reserveCapacity(min(retainLimit, Int(sampleRate * 30)))
    }

    /// The ceiling that applies right now: the smaller one while audio is being kept, the
    /// runaway backstop once it is not.
    private var activeLimit: Int { retains ? retainLimit : hardLimit }

    /// Records `samples`.
    ///
    /// - Returns: `true` exactly once — on the call that reaches the ceiling — so the
    ///   caller can end the dictation. Reporting it once matters: the tap fires ten times a
    ///   second, and a handler invoked on every one of them would be a stampede.
    @discardableResult
    func append(_ samples: [Float]) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Statistics first: they are the part that has to survive retention being dropped.
        frameCount += samples.count
        peak = max(peak, VoiceActivity.peak(samples[...]))
        if !speechDetected {
            speechDetected = VoiceActivity.containsSpeech(samples, sampleRate: sampleRate)
        }

        if retains, storage.count < retainLimit {
            let room = retainLimit - storage.count
            storage.append(contentsOf: samples.count <= room ? samples[...] : samples[..<room])
        }

        guard frameCount >= activeLimit, !reportedLimit else { return false }
        reportedLimit = true
        return true
    }

    /// Drops the retained copy and stops keeping any more.
    func stopRetaining() {
        lock.lock()
        defer { lock.unlock() }
        retains = false
        storage = []
    }

    /// Everything worth knowing about the recording. Empties the buffer.
    func summary() -> RecordingSummary {
        lock.lock()
        defer { lock.unlock() }
        let result = RecordingSummary(
            samples: storage,
            duration: Double(frameCount) / sampleRate,
            peak: peak,
            containsSpeech: speechDetected
        )
        storage = []
        return result
    }
}
