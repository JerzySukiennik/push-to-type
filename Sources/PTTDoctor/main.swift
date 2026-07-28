import Foundation
import PTTAudio
import PTTInsertion
import PTTSettings
import PTTSupport
import PTTWhisper

/// `ptt-doctor` — checks everything that can only fail on a real machine.
///
/// The unit tests cover pure logic. This covers the rest: is the model file intact, does
/// whisper.cpp actually link and run, how fast is inference here, is there a microphone,
/// are the permissions granted. It also gives a user something to run when dictation
/// misbehaves, instead of asking them to read a log.
///
///     swift run ptt-doctor [path/to/audio.wav]
///
/// Exits non-zero when a required check fails.

// MARK: - Reporting

/// Outcome of a single check.
enum Outcome: String {
    case pass = "  ok  "
    case warn = " warn "
    case fail = " FAIL "
}

/// Collects results so the tool can end with a verdict and a meaningful exit code.
@MainActor
final class Report {
    private(set) var failures = 0

    func note(_ outcome: Outcome, _ title: String, _ detail: String = "") {
        if outcome == .fail { failures += 1 }
        print("[\(outcome.rawValue)] \(title)")
        for line in detail.split(separator: "\n") {
            print("           \(line)")
        }
    }
}

// MARK: - Checks

@MainActor
struct Doctor {

    let report = Report()

    func run() async -> Int32 {
        print("PushToType diagnostics\n")

        let settings = SettingsStore().snapshot
        report.note(
            .pass,
            "Settings loaded",
            """
            hotkey \(settings.hotkey.displayString)
            model \(settings.model.displayName), language \(settings.language.displayName)
            streaming \(settings.streamingEnabled ? "on" : "off")
            """
        )

        checkModelFile(settings.model)
        await checkInference(settings)
        checkMicrophone()
        checkAccessibility()

        print("")
        if report.failures == 0 {
            print("All required checks passed.")
        } else {
            print("\(report.failures) check(s) failed.")
        }
        return report.failures == 0 ? 0 : 1
    }

    // MARK: Model

    private func checkModelFile(_ model: WhisperModel) {
        guard FileManager.default.fileExists(atPath: model.fileURL.path) else {
            report.note(.warn, "Model not downloaded", "the app fetches it on first use")
            return
        }

        if model.isDownloaded {
            report.note(.pass, "Model file", "\(model.fileURL.path) (\(model.displaySize))")
            return
        }

        let size = (try? FileManager.default
            .attributesOfItem(atPath: model.fileURL.path)[.size] as? Int64) ?? nil
        report.note(
            .fail,
            "Model file is damaged",
            """
            expected \(model.fileSize) bytes, found \(size.map(String.init) ?? "unknown")
            GGML header valid: \(model.hasValidHeader)
            delete it and let the app download it again
            """
        )
    }

    // MARK: Inference

    private func checkInference(_ settings: SettingsSnapshot) async {
        guard settings.model.isDownloaded else { return }

        let explicit = CommandLine.arguments.dropFirst().first.map(URL.init(fileURLWithPath:))
        guard let sample = explicit ?? Self.bundledSample() else {
            report.note(
                .warn,
                "No sample audio",
                "pass a .wav path, or run: git submodule update --init"
            )
            return
        }

        do {
            let engine = WhisperEngine()

            let loadStarted = Date()
            try await engine.load(settings.model)
            report.note(
                .pass,
                "Model loaded",
                String(format: "%.2f s", Date().timeIntervalSince(loadStarted))
            )

            let samples = try AudioFileLoader.samples(from: sample)
            let seconds = Double(samples.count) / WhisperEngine.requiredSampleRate

            let result = try await engine.transcribe(
                samples: samples,
                language: settings.language
            )
            let text = TranscriptPostProcessor(appendTrailingSpace: false).process(result.text)

            if text.isEmpty {
                report.note(.fail, "Transcription produced no text", sample.lastPathComponent)
            } else {
                report.note(
                    .pass,
                    "Transcription",
                    String(
                        format: "%.1f s of audio in %.2f s (%.1f× real time)\n“%@”",
                        seconds,
                        result.duration,
                        seconds / max(result.duration, 0.001),
                        text
                    )
                )
            }

            await engine.unload()
        } catch {
            report.note(.fail, "Inference failed", "\(error)")
        }
    }

    /// The whisper.cpp sample, when the submodule is checked out.
    private static func bundledSample() -> URL? {
        let candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Vendor/whisper.cpp/samples/jfk.wav")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    // MARK: Environment

    private func checkMicrophone() {
        switch MicrophonePermission.status {
        case .granted:
            report.note(.pass, "Microphone permission")
        case .notDetermined:
            report.note(.warn, "Microphone permission", "not requested yet")
        case .denied:
            report.note(
                .fail,
                "Microphone permission denied",
                "System Settings › Privacy & Security › Microphone"
            )
        }

        if MicrophonePermission.hasInputDevice {
            report.note(.pass, "Input device available")
        } else {
            report.note(.fail, "No audio input device")
        }
    }

    private func checkAccessibility() {
        if AccessibilityPermission.isTrusted {
            report.note(.pass, "Accessibility permission")
        } else {
            report.note(
                .warn,
                "Accessibility not granted",
                """
                text insertion will not work until it is
                \(AccessibilityPermission.settingsURL.absoluteString)
                """
            )
        }
    }
}

exit(await Doctor().run())
