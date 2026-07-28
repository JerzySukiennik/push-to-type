import CWhisper
import Foundation
import PTTSettings
import PTTSupport

/// Result of one inference pass.
public struct Transcription: Sendable, Equatable {
    /// Post-processed text, ready to insert.
    public let text: String
    /// Language whisper actually used (useful when detection is on).
    public let language: String
    /// Wall-clock duration of the inference, for the log and the About panel.
    public let duration: TimeInterval

    public init(text: String, language: String, duration: TimeInterval) {
        self.text = text
        self.language = language
        self.duration = duration
    }
}

/// Owns the whisper.cpp context and turns 16 kHz mono samples into text.
///
/// ## Threading
/// The type is an `actor`, so the context pointer has a single logical owner. The actual
/// `whisper_full` call is blocking, CPU-saturating work, so it is dispatched onto a
/// dedicated **serial** queue instead of running on a cooperative thread — that keeps the
/// Swift concurrency thread pool free and guarantees, by construction, that two passes
/// never touch the same context at once (whisper contexts are explicitly not thread-safe).
///
/// ## Lifetime
/// The context is created on first use and kept until `unload()`. Loading `base.en` costs
/// roughly a second and ~200 MB, which is why "keep model loaded" exists as a preference:
/// paying it once makes every subsequent dictation feel instant.
public actor WhisperEngine {

    /// Sample rate whisper.cpp requires. Everything upstream converts to this.
    public static let requiredSampleRate: Double = 16_000

    /// Shortest audio worth sending to the model. Below this whisper mostly hallucinates
    /// filler like "Thank you." out of room tone.
    public static let minimumSampleCount = Int(requiredSampleRate * 0.25)

    private var context: WhisperContext?
    private var loadedModel: WhisperModel?

    /// Serial queue for the blocking inference call. Serial is load-bearing: it is what
    /// prevents overlapping `whisper_full` calls on one context.
    private let inferenceQueue = DispatchQueue(
        label: "com.gzowo.PushToType.inference",
        qos: .userInitiated
    )

    public init() {
        Self.installLogBridge
    }

    /// Routes whisper.cpp's and ggml's chatter into `os.Logger` instead of stderr.
    ///
    /// Both libraries print a page of buffer sizes on every context creation. In a
    /// background app that output goes nowhere useful; in a terminal it buries the app's
    /// own messages. Sending it to the unified log keeps it available (`log stream`)
    /// without it being in the way. Runs exactly once, on first engine construction.
    private static let installLogBridge: Void = {
        whisper_log_set(
            { level, message, _ in
                guard let message else { return }
                let text = String(cString: message)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                switch level {
                case GGML_LOG_LEVEL_ERROR:
                    Log.whisper.error("whisper.cpp: \(text, privacy: .public)")
                case GGML_LOG_LEVEL_WARN:
                    Log.whisper.warning("whisper.cpp: \(text, privacy: .public)")
                default:
                    Log.whisper.debug("whisper.cpp: \(text, privacy: .public)")
                }
            },
            nil
        )
    }()

    // MARK: - Model lifecycle

    /// The model currently held in memory, if any.
    public var currentModel: WhisperModel? { loadedModel }

    /// Loads `model`, replacing any previously loaded one.
    ///
    /// Re-loading the model that is already resident is a no-op, so callers can treat this
    /// as "make sure the engine is ready" and call it on every dictation.
    ///
    /// - Throws: ``PTTError/modelMissing(name:)`` when the file is absent,
    ///           ``PTTError/modelLoadFailed(name:)`` when whisper.cpp rejects it.
    public func load(_ model: WhisperModel) async throws {
        if loadedModel == model, context != nil { return }

        guard FileManager.default.fileExists(atPath: model.fileURL.path) else {
            throw PTTError.modelMissing(name: model.displayName)
        }

        unload()

        let path = model.fileURL.path
        let started = Date()

        let newContext: WhisperContext? = await withCheckedContinuation { continuation in
            inferenceQueue.async {
                var params = whisper_context_default_params()
                // Metal is off in this build (Intel target), so asking for the GPU would
                // only add a failed backend probe to every load.
                params.use_gpu = false
                params.flash_attn = false
                let pointer = whisper_init_from_file_with_params(path, params)
                continuation.resume(returning: pointer.map(WhisperContext.init))
            }
        }

        guard let newContext else {
            Log.whisper.error("whisper_init failed for \(model.rawValue, privacy: .public)")
            throw PTTError.modelLoadFailed(name: model.displayName)
        }

        context = newContext
        loadedModel = model
        Log.whisper.info(
            "Loaded \(model.rawValue, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s"
        )
    }

    /// Releases the context and its memory. Safe to call when nothing is loaded.
    ///
    /// The C allocation is freed by ``WhisperContext``'s deinitialiser, so dropping the
    /// last reference here is sufficient — and correct even if a pass is still finishing,
    /// because the queue holds its own reference until it returns.
    public func unload() {
        guard context != nil else { return }
        context = nil
        loadedModel = nil
        Log.whisper.debug("Context released")
    }

    // MARK: - Inference

    /// Transcribes `samples` (16 kHz, mono, −1…1).
    ///
    /// - Parameters:
    ///   - samples: PCM float frames.
    ///   - language: `.auto` runs whisper's detection pass first.
    ///   - initialPrompt: text from earlier chunks of the same utterance. Conditioning on
    ///     it keeps punctuation and casing consistent across a streamed dictation.
    /// - Returns: the raw whisper output joined across segments, whitespace-trimmed.
    /// - Throws: ``PTTError/emptyRecording`` for too-short input,
    ///           ``PTTError/transcriptionFailed(reason:)`` when `whisper_full` fails,
    ///           `CancellationError` when the surrounding task is cancelled.
    public func transcribe(
        samples: [Float],
        language: Language,
        initialPrompt: String? = nil
    ) async throws -> Transcription {
        guard let context else {
            throw PTTError.transcriptionFailed(reason: "no model loaded")
        }
        guard samples.count >= Self.minimumSampleCount else {
            throw PTTError.emptyRecording
        }

        try Task.checkCancellation()

        let cancellation = CancellationFlag()
        let threads = Self.threadCount
        let started = Date()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                inferenceQueue.async {
                    do {
                        let result = try Self.runFull(
                            context: context,
                            samples: samples,
                            language: language,
                            initialPrompt: initialPrompt,
                            threads: threads,
                            cancellation: cancellation
                        )
                        continuation.resume(
                            returning: Transcription(
                                text: result.text,
                                language: result.language,
                                duration: Date().timeIntervalSince(started)
                            )
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    // MARK: - The blocking call

    /// Runs one `whisper_full` pass. Executes on `inferenceQueue`, never on an actor.
    private static func runFull(
        context: WhisperContext,
        samples: [Float],
        language: Language,
        initialPrompt: String?,
        threads: Int32,
        cancellation: CancellationFlag
    ) throws -> (text: String, language: String) {

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threads
        params.translate = false
        params.no_timestamps = true
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.suppress_nst = true
        params.detect_language = language.isAutomatic
        // Each dictation is independent: carrying whisper's internal text context between
        // them makes it echo the previous utterance when the new one is short.
        params.no_context = true
        // Greedy with a single candidate. Beam search roughly triples latency for a
        // barely measurable win on short push-to-talk utterances.
        params.greedy.best_of = 1
        params.temperature = 0.0
        params.temperature_inc = 0.2

        // Cancellation: ggml polls this between graph nodes, so a released key aborts a
        // long pass instead of burning the CPU to completion.
        params.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<CancellationFlag>.fromOpaque(userData)
                .takeUnretainedValue()
                .isCancelled
        }

        // The C struct borrows these buffers for the duration of the call, so they must
        // outlive it — hence the nested `withCString` scopes rather than temporaries.
        let languageCode = language.isAutomatic ? "auto" : language.whisperCode
        let status: Int32 = languageCode.withCString { languagePointer in
            params.language = languagePointer
            let run: () -> Int32 = {
                samples.withUnsafeBufferPointer { buffer in
                    whisper_full(
                        context.pointer, params, buffer.baseAddress, Int32(buffer.count)
                    )
                }
            }
            if let initialPrompt, !initialPrompt.isEmpty {
                return initialPrompt.withCString { promptPointer in
                    params.initial_prompt = promptPointer
                    return run()
                }
            }
            return run()
        }

        if cancellation.isCancelled { throw CancellationError() }
        guard status == 0 else {
            throw PTTError.transcriptionFailed(reason: "whisper_full returned \(status)")
        }

        var text = ""
        for index in 0..<whisper_full_n_segments(context.pointer) {
            guard let segment = whisper_full_get_segment_text(context.pointer, index)
            else { continue }
            text += String(cString: segment)
        }

        let detectedID = whisper_full_lang_id(context.pointer)
        let detected = whisper_lang_str(detectedID).map { String(cString: $0) } ?? languageCode

        return (text.trimmingCharacters(in: .whitespacesAndNewlines), detected)
    }

    // MARK: - Tuning

    /// Physical performance cores. Using the logical count (hyper-threads) measurably slows
    /// whisper down, because the GEMM kernels already saturate each core's execution ports.
    private static let threadCount: Int32 = {
        func sysctlInt(_ name: String) -> Int? {
            var value: Int = 0
            var size = MemoryLayout<Int>.size
            guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
            return value
        }
        let cores = sysctlInt("hw.perflevel0.physicalcpu")
            ?? sysctlInt("hw.physicalcpu")
            ?? ProcessInfo.processInfo.activeProcessorCount
        return Int32(max(1, min(cores, 8)))
    }()
}

/// Reference-counted owner of a `whisper_context *`.
///
/// This is the one audited `@unchecked Sendable` in the project. The unchecked part is
/// safe because of two invariants enforced by ``WhisperEngine``:
///
/// 1. The pointer is only ever dereferenced on `WhisperEngine.inferenceQueue`, which is
///    serial — so no two threads use the context simultaneously.
/// 2. `whisper_free` runs in `deinit`, and the queue's closures hold a strong reference
///    for the whole pass — so the context cannot be freed while it is in use.
private final class WhisperContext: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        whisper_free(pointer)
    }
}

/// Thread-safe boolean handed to ggml's abort callback.
///
/// A tiny class rather than an actor: the callback runs deep inside C code on the
/// inference thread and must answer synchronously.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
