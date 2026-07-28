import PTTSettings
import SwiftUI

/// First-run walkthrough for the two permissions the app cannot work without.
///
/// Shown once, and only when something is actually missing — an app that opens a window to
/// tell you everything is fine is an app that wasted your attention.
struct OnboardingView: View {

    @Bindable var model: SettingsViewModel
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("PushToType needs two permissions")
                    .font(.title3.weight(.semibold))
                Text("Both are granted in System Settings. Nothing leaves your Mac: speech is transcribed locally.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                OnboardingStep(
                    number: 1,
                    title: "Microphone",
                    detail: "So the app can hear you while the shortcut is held.",
                    isGranted: model.isMicrophoneGranted,
                    action: model.askForMicrophone
                )
                OnboardingStep(
                    number: 2,
                    title: "Accessibility",
                    detail: "So the transcript can be typed into the app you are using.",
                    isGranted: model.isAccessibilityGranted,
                    action: model.askForAccessibility
                )
            }

            HStack {
                Text("Hold \(model.settings.hotkey.displayString) anywhere to dictate.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(allGranted ? "Done" : "Continue anyway", action: onFinish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .task {
            await model.refreshPermissionStatus()
        }
        // Accessibility grants arrive without any notification, so the state is re-read
        // when the user comes back to this window rather than polled continuously.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await model.refreshPermissionStatus() }
        }
    }

    private var allGranted: Bool {
        model.isMicrophoneGranted && model.isAccessibilityGranted
    }
}

/// One numbered permission step.
private struct OnboardingStep: View {
    let number: Int
    let title: String
    let detail: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isGranted ? Color.green : Color.secondary.opacity(0.2))
                    .frame(width: 22, height: 22)
                if isGranted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .semibold))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !isGranted {
                Button("Grant…", action: action)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
