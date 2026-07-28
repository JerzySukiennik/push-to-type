import AVFoundation
import Foundation
import PTTSupport

/// Microphone authorisation, expressed as something the dictation flow can branch on.
public enum MicrophonePermission {

    public enum Status: Sendable, Equatable {
        /// Never asked. Requesting will show the system prompt.
        case notDetermined
        /// Granted — recording will work.
        case granted
        /// Denied or restricted by policy; only System Settings can change it.
        case denied
    }

    /// Current status, read without prompting. Cheap enough to call before every dictation.
    public static var status: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    /// Requests access, showing the system prompt if it has not been shown before.
    ///
    /// - Returns: `true` when recording is permitted afterwards.
    @discardableResult
    public static func request() async -> Bool {
        switch status {
        case .granted: return true
        case .denied: return false
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Log.audio.info("Microphone access \(granted ? "granted" : "denied", privacy: .public)")
            return granted
        }
    }

    /// Ensures access, throwing the typed error the UI knows how to explain.
    public static func require() async throws {
        guard await request() else { throw PTTError.microphoneDenied }
    }

    /// `true` when at least one audio input device exists.
    ///
    /// Distinguishes "permission denied" from "no microphone plugged in", which need
    /// different messages and different fixes.
    public static var hasInputDevice: Bool {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return !discovery.devices.isEmpty
    }
}
