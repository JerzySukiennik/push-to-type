import PTTHotkeys
import PTTSettings
import SwiftUI

/// The whole settings surface: one compact window, no tabs.
///
/// Everything fits on one scrolling form, so the user never has to hunt for the setting
/// they came for. Modes come first because they are what most visits are about.
struct SettingsView: View {

    @Bindable var model: SettingsViewModel

    /// A local copy of the modes, so edits re-render immediately. The store persists to
    /// `UserDefaults`, which `@Observable` does not track, so the view keeps its own copy
    /// and writes through ``SettingsViewModel/update(_:)``.
    @State private var modes: [DictationMode] = []
    @State private var apiKeyDraft = ""

    /// Bindings into the settings store for the simple scalar controls.
    private var bindableSettings: Bindable<SettingsStore> {
        Bindable(model.settings)
    }

    var body: some View {
        Form {
            modesSection
            aiSection
            speechSection
            vocabularySection
            textSection
            permissionsSection

            if let error = model.lastError {
                Section {
                    Label(error.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            modes = model.settings.modes
            model.refreshModels()
            model.refreshAPIKeyState()
            await model.refreshPermissionStatus()
        }
    }

    // MARK: - Modes

    private var modesSection: some View {
        Section("Dictation modes") {
            ForEach(modes) { mode in
                ModeRow(mode: mode) { updated in
                    model.update(updated)
                    modes = model.settings.modes
                }
            }
            Text("Each mode has its own shortcut. Raw inserts exactly what you said, offline. A mode with an instruction sends the text to Gemini to be rewritten before it is inserted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - AI formatting

    private var aiSection: some View {
        Section("AI formatting (Gemini)") {
            LabeledContent("API key") {
                HStack {
                    Label(
                        model.hasAPIKey ? "Saved" : "Not set",
                        systemImage: model.hasAPIKey ? "checkmark.circle.fill" : "key"
                    )
                    .foregroundStyle(model.hasAPIKey ? .green : .secondary)
                    if model.hasAPIKey {
                        Button("Remove") { model.saveGeminiKey("") }
                            .buttonStyle(.link)
                    }
                }
            }

            HStack {
                SecureField("Paste your Gemini API key", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    model.saveGeminiKey(apiKeyDraft)
                    apiKeyDraft = ""
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Picker("Model", selection: bindableSettings.geminiModel) {
                Text("Gemini 2.0 Flash").tag("gemini-2.0-flash")
                Text("Gemini 2.5 Flash").tag("gemini-2.5-flash")
                Text("Gemini 2.5 Pro").tag("gemini-2.5-pro")
            }

            Text("The key is stored in your login keychain, never in a file. Only the transcript and the mode's instruction are sent — nothing else. Raw dictation stays fully offline.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Speech

    private var speechSection: some View {
        Section("Speech") {
            Picker("Language", selection: bindableSettings.language) {
                ForEach(Language.available(for: model.settings.model)) { language in
                    Text(language.displayName).tag(language)
                }
            }

            Picker("Model", selection: bindableSettings.model) {
                ForEach(WhisperModel.allCases) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
            }
            modelStatusRow

            Toggle("Transcribe while speaking", isOn: bindableSettings.streamingEnabled)
            Toggle("Keep the model in memory", isOn: bindableSettings.keepModelLoaded)
        }
    }

    private var vocabularySection: some View {
        Section("Your words") {
            TextEditor(text: bindableSettings.customVocabulary)
                .font(.body)
                .frame(minHeight: 60)
                .overlay(alignment: .topLeading) {
                    if model.settings.customVocabulary.isEmpty {
                        Text("Gzowo, GSP, three.js, Rapier")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            Text("Names the model keeps getting wrong, separated by commas. A nudge, not a dictionary.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var textSection: some View {
        Section("Text") {
            Toggle("Insert directly into the text field", isOn: bindableSettings.preferAccessibilityInsertion)
            Toggle("Capitalise the first letter", isOn: bindableSettings.capitalizeFirstLetter)
            Toggle("Add a space at the end", isOn: bindableSettings.appendTrailingSpace)
            Toggle("Show the on-screen indicator", isOn: bindableSettings.showHUD)
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            PermissionRow(
                title: "Microphone",
                isGranted: model.isMicrophoneGranted,
                action: model.askForMicrophone
            )
            PermissionRow(
                title: "Accessibility",
                isGranted: model.isAccessibilityGranted,
                action: model.askForAccessibility
            )
        }
    }

    @ViewBuilder
    private var modelStatusRow: some View {
        let current = model.settings.model
        if let progress = model.progress(for: current) {
            ProgressView(value: progress) {
                Text("Downloading \(current.displayName)")
            }
        } else if model.downloadedModels.contains(current) {
            LabeledContent("Status") {
                HStack {
                    Text("Ready · \(current.displaySize)").foregroundStyle(.secondary)
                    Button("Remove") { model.delete(current) }.buttonStyle(.link)
                }
            }
        } else {
            LabeledContent("Status") {
                HStack {
                    Text("Not downloaded").foregroundStyle(.secondary)
                    Button("Download \(current.displaySize)") { model.download(current) }
                }
            }
        }
    }
}

/// One dictation mode: its name, its shortcut recorder, and — for refined modes — the
/// instruction sent to the model.
private struct ModeRow: View {
    let mode: DictationMode
    let onChange: (DictationMode) -> Void

    @State private var recorder = HotkeyRecorder()
    @State private var isRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(mode.name).font(.body.weight(.medium))
                Spacer()
                Button {
                    toggleRecording()
                } label: {
                    Text(shortcutLabel)
                        .frame(minWidth: 96)
                        .monospaced()
                }
                .buttonStyle(.bordered)
                .help("Click, then press a combination or hold two modifiers and let go. Escape clears it.")
            }

            if mode.isRefined {
                TextEditor(text: promptBinding)
                    .font(.callout)
                    .frame(minHeight: 54)
                    .overlay(alignment: .topLeading) {
                        if mode.refinementPrompt.isEmpty {
                            Text("How should the model rewrite it?")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .padding(.vertical, 2)
    }

    private var shortcutLabel: String {
        if isRecording { return "Press or hold…" }
        return mode.hotkey?.displayString ?? "Set…"
    }

    /// Writes prompt edits straight through to the store as they happen.
    private var promptBinding: Binding<String> {
        Binding(
            get: { mode.refinementPrompt },
            set: { var updated = mode; updated.refinementPrompt = $0; onChange(updated) }
        )
    }

    private func toggleRecording() {
        if isRecording {
            recorder.stop()
            isRecording = false
            return
        }
        isRecording = true
        recorder.start { binding in
            isRecording = false
            // Escape returns nil: for a mode, that clears the shortcut rather than
            // cancelling, so an AI mode can be turned off without deleting its prompt. The
            // raw mode is the exception — without a shortcut there is no dictation at all,
            // so a cleared raw shortcut is ignored.
            if binding == nil, mode.id == DictationMode.rawModeID { return }
            var updated = mode
            updated.hotkey = binding
            onChange(updated)
        }
    }
}

/// A permission line: name, state, and the one button that can change it.
private struct PermissionRow: View {
    let title: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Label(
                    isGranted ? "Granted" : "Not granted",
                    systemImage: isGranted ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(isGranted ? .green : .secondary)
                .labelStyle(.titleAndIcon)

                if !isGranted {
                    Button("Grant…", action: action)
                }
            }
        }
    }
}
