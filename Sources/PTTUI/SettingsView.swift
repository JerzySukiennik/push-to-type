import PTTHotkeys
import PTTSettings
import SwiftUI

/// The whole settings surface: one compact window, four sections, no tabs.
///
/// A menu bar utility with six preferences does not need a tab bar — everything fits on
/// one screen, which also means the user never has to hunt for the setting they came for.
struct SettingsView: View {

    @Bindable var model: SettingsViewModel
    @State private var recorder = HotkeyRecorder()
    @State private var isRecordingHotkey = false

    /// Bindings into the settings store.
    ///
    /// The store is a `let` on the view model — it is a dependency, not state — so the
    /// two-way bindings the controls need are made here instead of through `$model`.
    private var bindableSettings: Bindable<SettingsStore> {
        Bindable(model.settings)
    }

    var body: some View {
        Form {
            Section("Shortcut") {
                hotkeyRow
                Text(shortcutExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                Text("Processes each phrase during the pause after it, so releasing the key finishes almost immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Keep the model in memory", isOn: bindableSettings.keepModelLoaded)
            }

            Section("Your words") {
                TextEditor(text: bindableSettings.customVocabulary)
                    .font(.body)
                    .frame(minHeight: 66)
                    .overlay(alignment: .topLeading) {
                        if model.settings.customVocabulary.isEmpty {
                            Text("Gzowo, GSP, three.js, Rapier")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                Text("Names the model keeps getting wrong, separated by commas. Listing them makes those spellings more likely — it is a nudge, not a dictionary, so a word can still come out wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Text") {
                Toggle("Insert directly into the text field", isOn: bindableSettings.preferAccessibilityInsertion)
                Text("When an app does not support it, PushToType pastes instead and restores your clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Capitalise the first letter", isOn: bindableSettings.capitalizeFirstLetter)
                Toggle("Add a space at the end", isOn: bindableSettings.appendTrailingSpace)
                Toggle("Show the on-screen indicator", isOn: bindableSettings.showHUD)
            }

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

            if let error = model.lastError {
                Section {
                    Label(error.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            model.refreshModels()
            await model.refreshPermissionStatus()
        }
    }

    // MARK: - Rows

    /// The two shapes of shortcut behave differently enough towards other apps that the
    /// explanation has to follow the current choice rather than describe one of them.
    private var shortcutExplanation: String {
        if model.settings.hotkey.isModifierOnly {
            return """
                Hold the modifiers, speak, then release. Other apps still receive them \
                normally — PushToType only watches. Pressing any key during the hold \
                cancels, so ordinary shortcuts still work.
                """
        }
        return """
            Hold the shortcut, speak, then release. While it is registered, no other app \
            receives this combination.
            """
    }

    private var hotkeyRow: some View {
        LabeledContent("Shortcut") {
            Button {
                toggleRecording()
            } label: {
                Text(isRecordingHotkey ? "Press or hold…" : model.settings.hotkey.displayString)
                    .frame(minWidth: 120)
                    .monospaced()
            }
            .buttonStyle(.bordered)
            .help(
                "Click, then either press a combination, or hold two modifiers and let go. "
                    + "Escape cancels."
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
                    Text("Ready · \(current.displaySize)")
                        .foregroundStyle(.secondary)
                    Button("Remove") { model.delete(current) }
                        .buttonStyle(.link)
                }
            }
        } else {
            LabeledContent("Status") {
                HStack {
                    Text("Not downloaded")
                        .foregroundStyle(.secondary)
                    Button("Download \(current.displaySize)") { model.download(current) }
                }
            }
        }
    }

    private func toggleRecording() {
        if isRecordingHotkey {
            recorder.stop()
            isRecordingHotkey = false
            return
        }

        isRecordingHotkey = true
        recorder.start { binding in
            isRecordingHotkey = false
            guard let binding else { return }
            if model.apply(hotkey: binding) {
                model.settings.hotkey = binding
            }
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
