import Foundation
import PTTAudio
import PTTInsertion
import PTTRefine
import PTTSettings
import PTTSupport
import PTTUI
import PTTWhisper

/// The push-to-talk flow, start to finish.
///
/// This is the only type that knows the whole story: key down → record → transcribe →
/// insert → key up. Every module it drives is injected, and none of them know about each
/// other, which is what keeps this readable at ~200 lines instead of becoming the usual
/// "app controller" swamp.
///
/// ## Concurrency
/// The controller is `@MainActor`. It never blocks: the recorder, the engine and the model
/// manager are actors, and the work between key-down and key-up runs in a single child
/// task that is cancelled if the user starts a new dictation. That cancellation is the
/// reason a fast press–release–press cannot interleave two dictations.
@MainActor
final class DictationController {

    // MARK: Dependencies

    private let settings: SettingsStore
    private let recorder: AudioRecorder
    private let engine: WhisperEngine
    private let models: ModelManager
    private let inserter: TextInsertionService
    private let hud: HUDController

    /// Rewrites the transcript for refined modes; `nil` disables refinement entirely.
    private let refiner: (any TextRefiner)?

    /// Notified on every state change, for the menu bar glyph and header line.
    var onPhaseChange: ((DictationPhase) -> Void)?

    // MARK: State

    private(set) var phase: DictationPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            onPhaseChange?(phase)
        }
    }

    /// Everything belonging to the dictation currently in progress.
    private var session: Session?

    init(
        settings: SettingsStore,
        recorder: AudioRecorder,
        engine: WhisperEngine,
        models: ModelManager,
        inserter: TextInsertionService,
        hud: HUDController,
        refiner: (any TextRefiner)? = nil
    ) {
        self.settings = settings
        self.recorder = recorder
        self.engine = engine
        self.models = models
        self.inserter = inserter
        self.hud = hud
        self.refiner = refiner
    }

    // MARK: - Hotkey

    /// A mode's shortcut went down: start recording in that mode.
    ///
    /// Recording starts *before* the model is confirmed loaded. Waiting for a cold model
    /// would swallow the first word, and the audio simply queues until inference is ready.
    ///
    /// If another mode is already recording, it is pre-empted. This is what makes switching
    /// modes mid-hold work: holding ⌃⌥ starts raw, and pressing P while still holding turns
    /// it into the Prompt mode's shortcut — the raw hold is abandoned and Prompt takes over,
    /// regardless of which of the two events the system delivers first.
    func hotkeyPressed(mode: DictationMode) {
        var preempting = false
        if let current = session {
            if current.mode.id == mode.id { return }  // same shortcut twice
            if !current.isFinishing {
                // Pre-empt, but only cancel the previous session's tasks here — not the
                // recorder. The recorder is shared, and tearing it down on a detached task
                // would race the new session's start(): the new one would find the mic
                // still busy, bail out, and then the old teardown would stop the mic it was
                // about to use. Instead the new capture awaits the teardown first, below.
                discardTasks(current)
                preempting = true
            }
        }

        let configuration = settings.snapshot
        hud.isEnabled = configuration.showHUD

        let session = Session(configuration: configuration, mode: mode)
        self.session = session
        Log.app.info("Started mode \(mode.name, privacy: .public)\(preempting ? " (pre-empting)" : "")")

        phase = .listening(level: 0)
        hud.show(phase)

        session.work = Task { [weak self] in
            guard let self else { return }
            // Serialise on the recorder: stop the pre-empted recording before starting the
            // new one, in the same task, so there is no window where both touch it.
            if preempting { await self.recorder.abort() }
            await self.runCapture(session)
        }
    }

    /// A mode's shortcut came up: stop recording and deliver the transcript — but only if
    /// the mode that came up is the one currently recording. A release for a mode that was
    /// already pre-empted is ignored.
    func hotkeyReleased(modeID: String) {
        guard let session, session.mode.id == modeID, !session.isFinishing else { return }
        session.isFinishing = true

        session.finish = Task { [weak self] in
            await self?.finishCapture(session)
        }
    }

    /// Ends a dictation that has run to the recorder's ceiling.
    ///
    /// The old behaviour was to keep recording and throw the surplus away, so a long
    /// dictation lost its ending with no indication that anything had happened. Finishing
    /// early keeps every word that was captured and says so; the alternative — silent
    /// truncation — is the worst of the three options available.
    private func stopAtDurationLimit() {
        guard let session, !session.isFinishing else { return }
        Log.app.info("Reached the recording ceiling")
        session.reachedDurationLimit = true
        hotkeyReleased(modeID: session.mode.id)
    }

    /// Abandons the dictation being *recorded* by `modeID`, inserting nothing.
    ///
    /// The id check is load-bearing. A modifier-only shortcut reports a cancelled hold
    /// whenever ⌃⌥ turns out to be the start of a larger chord — but by then the dictation
    /// may already have been pre-empted by another mode, or released and now transcribing.
    /// Cancelling only when the id still matches the recording session keeps a stray cancel
    /// from killing an unrelated, in-flight dictation.
    func cancelDictation(modeID: String) {
        guard let session, session.mode.id == modeID, !session.isFinishing else { return }
        discardTasks(session)
        // A genuine cancel does stop the mic — nothing is taking it over.
        Task { [recorder] in await recorder.abort() }
        phase = .idle
        hud.hide()
    }

    /// Cancels a session's tasks and streams, but does *not* stop the recorder.
    ///
    /// Split out from stopping the mic because pre-emption needs the tasks cancelled
    /// without the recorder touched — the incoming session owns the mic next and stops it
    /// itself, in order. A plain cancel calls this and then stops the mic separately.
    private func discardTasks(_ session: Session) {
        if self.session === session { self.session = nil }
        session.work?.cancel()
        session.finish?.cancel()
        session.chunks.finish()
        Task { [transcriber = session.transcriber] in await transcriber?.cancel() }
    }

    /// Tears down whatever is in flight, at quit.
    func shutDown() {
        guard let session else { return }
        self.session = nil
        session.work?.cancel()
        session.finish?.cancel()
        session.chunks.finish()
        Task { [recorder] in await recorder.abort() }
    }

    // MARK: - Capture

    /// Starts the microphone, then brings the engine up while audio is already flowing.
    private func runCapture(_ session: Session) async {
        do {
            let continuation = session.chunks.continuation
            try await recorder.start(
                onChunk: { samples in
                    continuation.yield(samples)
                },
                onLimitReached: { [weak self] in
                    // Fired on the audio thread; hop to the main actor to end the
                    // dictation the same way a key release would.
                    Task { @MainActor in self?.stopAtDurationLimit() }
                }
            )

            // Consume in parallel with the engine warm-up: the loop updates the level
            // meter straight away and parks the audio until the transcriber exists.
            session.consumer = Task { [weak self] in
                await self?.consume(session)
            }

            if session.configuration.streamingEnabled {
                try await prepareEngine(for: session)
                let transcriber = StreamingTranscriber(
                    engine: engine,
                    language: session.configuration.language,
                    vocabulary: session.vocabulary
                )
                session.transcriber = transcriber
                await flushBacklog(of: session, into: transcriber)

                // The transcriber now owns every sample recorded so far, so the recorder's
                // copy is dead weight. Dropping it is what lifts the length ceiling: from
                // here on the dictation costs a few bytes a minute instead of 3.8 MB.
                await recorder.releaseRetainedAudio()
            }
        } catch is CancellationError {
            // Nothing to report: the user let go or started again.
        } catch {
            await fail(session, with: error)
        }
    }

    /// Reads captured audio: updates the meter, and feeds the transcriber once it exists.
    private func consume(_ session: Session) async {
        for await chunk in session.chunks.stream {
            guard !Task.isCancelled else { return }

            if case .listening = phase {
                phase = .listening(level: VoiceActivity.peak(chunk[...]))
                hud.show(phase)
            }

            if let transcriber = session.transcriber {
                await transcriber.append(chunk)
            } else {
                session.backlog.append(chunk)
            }
        }
    }

    /// Hands the audio recorded during engine warm-up to the transcriber, in order.
    private func flushBacklog(of session: Session, into transcriber: StreamingTranscriber) async {
        let backlog = session.backlog
        session.backlog = []
        for chunk in backlog {
            await transcriber.append(chunk)
        }
    }

    /// Ensures the configured model is downloaded and loaded.
    private func prepareEngine(for session: Session) async throws {
        let model = session.configuration.model

        if await engine.currentModel != model {
            if !model.isDownloaded {
                phase = .downloading(model: model.displayName, progress: 0)
                hud.show(phase)

                _ = try await models.ensureAvailable(model) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, case .downloading = self.phase else { return }
                        self.phase = .downloading(model: model.displayName, progress: fraction)
                        self.hud.show(self.phase)
                    }
                }
                // Recording continued throughout; go back to showing the meter.
                phase = .listening(level: 0)
                hud.show(phase)
            }
            try await engine.load(model)
        }
    }

    // MARK: - Finishing

    /// Stops the microphone, resolves the transcript and inserts it.
    private func finishCapture(_ session: Session) async {
        let recording = await recorder.stop()
        session.chunks.finish()
        await session.consumer?.value  // drains whatever is still buffered

        // The slot is freed as soon as the microphone is, not when the transcript is
        // ready. Push-to-talk is used in bursts: making the user wait out the previous
        // utterance's inference before they can start the next one is a stutter they did
        // not ask for, and the two dictations share nothing but the recorder.
        if self.session === session { self.session = nil }

        logCapture(recording)

        do {
            // The speech test comes from the summary, not from the audio: once retention
            // has been released there is no audio here to test, and the summary's answer
            // was computed over the whole recording as it arrived.
            guard recording.containsSpeech else { throw PTTError.emptyRecording }

            phase = .transcribing
            hud.show(phase)

            let raw: String
            if let transcriber = session.transcriber {
                raw = try await transcriber.finish()
            } else {
                // Streaming is off, or the engine came up after the key was released —
                // either way retention was never released, so the audio is still here.
                try await prepareEngine(for: session)
                raw = try await engine.transcribe(
                    samples: recording.samples,
                    language: session.configuration.language,
                    initialPrompt: InitialPrompt(vocabulary: session.vocabulary).text
                ).text
            }

            let cleaned = TranscriptPostProcessor(
                capitalizeFirstLetter: session.configuration.capitalizeFirstLetter,
                appendTrailingSpace: session.configuration.appendTrailingSpace
            ).process(raw)

            // The transcript itself is never logged: it is whatever the user just said.
            Log.app.info("Transcribed \(raw.count) raw characters")
            guard !cleaned.isEmpty else { throw PTTError.emptyTranscript }

            let text = await refine(cleaned, for: session)

            try await inserter.insert(
                text,
                preferAccessibility: session.configuration.preferAccessibilityInsertion
            )

            phase = .inserted(characters: text.count)
            Log.app.info("Dictated \(text.count) characters")

            // The HUD's closing state, in priority order: a refinement that fell back to
            // raw is the most important thing to explain, then a self-imposed stop, then
            // the ordinary silent dismissal.
            if let refinementError = session.refinementError {
                hud.flash(.failed(refinementError), for: .seconds(3))
            } else if session.reachedDurationLimit {
                // Which ceiling was hit depends on whether the audio had to be kept.
                let ceiling = recording.samples.isEmpty
                    ? AudioRecorder.streamingLimit
                    : AudioRecorder.retainedAudioLimit
                phase = .limitReached(minutes: Int(ceiling / 60))
                hud.flash(phase, for: .seconds(3))
            } else {
                hud.hide()
            }

            if !session.configuration.keepModelLoaded {
                await engine.unload()
            }
            phase = .idle
        } catch is CancellationError {
            phase = .idle
            hud.hide()
        } catch {
            await fail(session, with: error)
        }
    }

    /// Records what the microphone actually delivered.
    ///
    /// When a dictation comes back empty there are three candidates — nothing was captured,
    /// something was captured but too quietly to pass the gate, or the audio was fine and
    /// the model returned nothing — and they need completely different fixes. One line in
    /// the log tells them apart, without the transcript itself ever being written down.
    private func logCapture(_ recording: RecordingSummary) {
        Log.app.info(
            """
            Captured \(recording.duration, format: .fixed(precision: 2)) s — \
            peak \(recording.peak, format: .fixed(precision: 4)), \
            gate \(recording.containsSpeech ? "passed" : "REJECTED", privacy: .public), \
            audio kept: \(recording.samples.isEmpty ? "no" : "yes", privacy: .public)
            """
        )
    }

    /// Applies the mode's refinement to `text`, or returns it unchanged.
    ///
    /// Refinement is best-effort by design: if the network is down, the key is wrong, or
    /// the model returns nothing, the *raw* transcript is inserted rather than nothing at
    /// all. Losing the formatting is a small disappointment; losing the words you just
    /// spoke is not acceptable. The failure is remembered on the session so the HUD can
    /// explain it once the text is safely in.
    private func refine(_ text: String, for session: Session) async -> String {
        guard session.mode.isRefined, let refiner else { return text }

        phase = .refining(mode: session.mode.name)
        hud.show(phase)

        do {
            let refined = try await refiner.refine(
                text,
                instruction: session.mode.refinementPrompt
            )
            Log.app.info(
                "Refined via \(session.mode.name, privacy: .public): \(refined.count) chars"
            )
            return session.configuration.appendTrailingSpace ? refined + " " : refined
        } catch is CancellationError {
            return text
        } catch {
            let pttError = (error as? PTTError)
                ?? .refinementFailed(reason: error.localizedDescription)
            Log.app.error("Refinement failed: \(pttError.message, privacy: .public)")
            session.refinementError = pttError
            return text
        }
    }

    /// Reports an error through the HUD and returns to idle.
    private func fail(_ session: Session, with error: Error) async {
        let pttError = (error as? PTTError)
            ?? .transcriptionFailed(reason: error.localizedDescription)

        if self.session === session {
            await recorder.abort()
            self.session = nil
        }
        session.chunks.finish()
        await session.transcriber?.cancel()

        Log.app.error("Dictation failed: \(pttError.message, privacy: .public)")

        phase = .failed(pttError)
        hud.flash(
            phase,
            for: pttError.isBenign ? .milliseconds(900) : .milliseconds(2600)
        )
        phase = .idle
    }
}

// MARK: - Session

/// The mutable parts of one dictation, so the controller itself stays stateless between
/// key presses and nothing leaks from a cancelled attempt into the next one.
@MainActor
private final class Session {

    let configuration: SettingsSnapshot

    /// The mode this dictation runs in — its shortcut identity, and whether and how the
    /// transcript is refined.
    let mode: DictationMode

    let chunks = ChunkChannel()

    /// The custom vocabulary, parsed once per dictation rather than per chunk.
    let vocabulary: [String]

    var work: Task<Void, Never>?
    var consumer: Task<Void, Never>?
    var finish: Task<Void, Never>?
    var transcriber: StreamingTranscriber?

    /// Audio captured before the transcriber existed, kept in order.
    var backlog: [[Float]] = []

    /// Set the moment the key comes up, so a repeated release is ignored.
    var isFinishing = false

    /// `true` when the recorder's ceiling ended this dictation rather than the user.
    var reachedDurationLimit = false

    /// Set when refinement was attempted and failed, so the HUD can explain that the raw
    /// transcript was inserted instead.
    var refinementError: PTTError?

    init(configuration: SettingsSnapshot, mode: DictationMode) {
        self.configuration = configuration
        self.mode = mode
        vocabulary = InitialPrompt.parseVocabulary(configuration.customVocabulary)
    }
}

/// An `AsyncStream` of audio chunks, with its continuation kept alongside it.
///
/// The buffer is unbounded on purpose: it absorbs the audio recorded while a cold model
/// loads, which is the only time the consumer is not keeping up. At 16 kHz mono that is
/// 64 kB per second, for the second or so a model takes to load.
private struct ChunkChannel {
    let stream: AsyncStream<[Float]>
    let continuation: AsyncStream<[Float]>.Continuation

    init() {
        (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
    }

    func finish() {
        continuation.finish()
    }
}
