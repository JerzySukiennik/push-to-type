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

    /// Called once if a dictation runs to ``maximumDuration``.
    public typealias LimitHandler = @Sendable () -> Void

    /// Longest single dictation.
    ///
    /// A cap has to exist — a stuck key would otherwise fill memory until the app died —
    /// but its old value of two minutes was both short and, worse, *silent*: everything
    /// past it was dropped on the floor with nothing to show for it. Five minutes is more
    /// than any push-to-talk utterance, costs 19 MB while recording and nothing at all
    /// once it ends, and reaching it now stops the dictation properly instead of quietly
    /// eating the rest.
    public static let maximumDuration: TimeInterval = 300

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
    ///   recording reaches ``maximumDuration``. The caller is expected to end the dictation
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
            capacity: Int(WhisperSampleRate.value * Self.maximumDuration)
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
            let wasFull = capture.append(samples)
            onChunk(samples)
            if wasFull { onLimitReached() }
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

    /// Stops capturing and returns everything recorded, resampled to 16 kHz mono.
    ///
    /// Returns an empty array when nothing was captured; the caller decides whether that
    /// is an error, because a streaming dictation may already hold the text it needs.
    @discardableResult
    public func stop() -> [Float] {
        guard let engine else { return [] }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Dropping the reference releases the audio unit, which is what actually turns the
        // microphone indicator off.
        self.engine = nil

        let samples = buffer?.takeAll() ?? []
        buffer = nil
        Log.audio.debug("Recording stopped: \(samples.count) samples")
        return samples
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

/// Accumulates samples written from the audio thread.
///
/// A plain lock rather than an actor: the render thread cannot `await`, and the critical
/// section is a single `append` of a few hundred floats — orders of magnitude shorter than
/// the buffer interval, so contention never approaches a drop-out.
private final class CaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float]
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        storage = []
        storage.reserveCapacity(min(capacity, Int(WhisperSampleRate.value * 30)))
    }

    /// Appends up to the capacity limit.
    ///
    /// - Returns: `true` exactly once — on the call that fills the buffer — so the caller
    ///   can end the dictation. Reporting it only once matters: the tap fires ten times a
    ///   second, and a handler invoked on every one of them would be a stampede.
    @discardableResult
    func append(_ samples: [Float]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storage.count < capacity else { return false }

        let room = capacity - storage.count
        if samples.count <= room {
            storage.append(contentsOf: samples)
        } else {
            storage.append(contentsOf: samples[..<room])
        }
        return storage.count >= capacity
    }

    /// Returns everything captured and empties the buffer.
    func takeAll() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let result = storage
        storage = []
        return result
    }
}
