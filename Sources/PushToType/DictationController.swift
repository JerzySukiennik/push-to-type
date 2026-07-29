import Foundation
import PTTAudio
import PTTInsertion
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
        hud: HUDController
    ) {
        self.settings = settings
        self.recorder = recorder
        self.engine = engine
        self.models = models
        self.inserter = inserter
        self.hud = hud
    }

    // MARK: - Hotkey

    /// The shortcut went down: start recording immediately.
    ///
    /// Recording starts *before* the model is confirmed loaded. Waiting for a cold model
    /// would swallow the first word, and the audio simply queues until inference is ready.
    func hotkeyPressed() {
        guard session == nil else { return }

        let configuration = settings.snapshot
        hud.isEnabled = configuration.showHUD

        let session = Session(configuration: configuration)
        self.session = session

        phase = .listening(level: 0)
        hud.show(phase)

        session.work = Task { [weak self] in
            await self?.runCapture(session)
        }
    }

    /// The shortcut came up: stop recording and deliver the transcript.
    func hotkeyReleased() {
        guard let session, !session.isFinishing else { return }
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
        Log.app.info("Reached the \(Int(AudioRecorder.maximumDuration)) s recording limit")
        session.reachedDurationLimit = true
        hotkeyReleased()
    }

    /// Abandons the dictation currently being *recorded*, inserting nothing.
    ///
    /// Deliberately does nothing once the key has been released. A modifier-only shortcut
    /// reports a cancelled hold whenever ⌃⌥ turns out to be the start of ⌃⌥⌘F — and that
    /// hold is not necessarily the one that started the dictation still finishing in the
    /// background. Without this guard, reaching for an ordinary shortcut kills the
    /// transcription of whatever was said a moment earlier, which is exactly what the log
    /// showed as `whisper_full_with_state: failed to encode`.
    func cancelDictation() {
        guard let session, !session.isFinishing else { return }
        self.session = nil

        session.work?.cancel()
        session.finish?.cancel()
        session.chunks.finish()
        Task { [recorder] in await recorder.abort() }
        Task { [transcriber = session.transcriber] in await transcriber?.cancel() }

        phase = .idle
        hud.hide()
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
        let samples = await recorder.stop()
        session.chunks.finish()
        await session.consumer?.value  // drains whatever is still buffered

        // The slot is freed as soon as the microphone is, not when the transcript is
        // ready. Push-to-talk is used in bursts: making the user wait out the previous
        // utterance's inference before they can start the next one is a stutter they did
        // not ask for, and the two dictations share nothing but the recorder.
        if self.session === session { self.session = nil }

        logCapture(samples)

        do {
            guard VoiceActivity.containsSpeech(samples, sampleRate: WhisperEngine.requiredSampleRate)
            else {
                throw PTTError.emptyRecording
            }

            phase = .transcribing
            hud.show(phase)

            let raw: String
            if let transcriber = session.transcriber {
                raw = try await transcriber.finish()
            } else {
                // Streaming is off, or the engine came up after the key was released.
                try await prepareEngine(for: session)
                raw = try await engine.transcribe(
                    samples: samples,
                    language: session.configuration.language,
                    initialPrompt: InitialPrompt(vocabulary: session.vocabulary).text
                ).text
            }

            let text = TranscriptPostProcessor(
                capitalizeFirstLetter: session.configuration.capitalizeFirstLetter,
                appendTrailingSpace: session.configuration.appendTrailingSpace
            ).process(raw)

            // The transcript itself is never logged: it is whatever the user just said.
            Log.app.info("Transcribed \(raw.count) raw characters")
            guard !text.isEmpty else { throw PTTError.emptyTranscript }

            try await inserter.insert(
                text,
                preferAccessibility: session.configuration.preferAccessibilityInsertion
            )

            phase = .inserted(characters: text.count)
            Log.app.info("Dictated \(text.count) characters")

            // Say why it ended on its own, otherwise the user is left wondering why the
            // key stopped working mid-sentence.
            if session.reachedDurationLimit {
                phase = .limitReached(minutes: Int(AudioRecorder.maximumDuration / 60))
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
    private func logCapture(_ samples: [Float]) {
        let seconds = Double(samples.count) / WhisperEngine.requiredSampleRate
        let peak = VoiceActivity.peak(samples[...])
        let rms = VoiceActivity.rms(samples[...])
        let passesGate = VoiceActivity.containsSpeech(
            samples,
            sampleRate: WhisperEngine.requiredSampleRate
        )

        Log.app.info(
            """
            Captured \(seconds, format: .fixed(precision: 2)) s — \
            peak \(peak, format: .fixed(precision: 4)), \
            rms \(rms, format: .fixed(precision: 4)), \
            gate \(passesGate ? "passed" : "REJECTED", privacy: .public)
            """
        )
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

    init(configuration: SettingsSnapshot) {
        self.configuration = configuration
        vocabulary = InitialPrompt.parseVocabulary(configuration.customVocabulary)
    }
}

/// An `AsyncStream` of audio chunks, with its continuation kept alongside it.
///
/// The buffer is unbounded on purpose: it absorbs the audio recorded while a cold model
/// loads. At 16 kHz mono that is 64 kB per second — bounded in practice by the recorder's
/// own two-minute cap.
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
