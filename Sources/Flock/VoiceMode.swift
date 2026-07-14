import AVFoundation
import AppKit

/// Microphone access helper for Claude Code's voice dictation (`/voice`).
///
/// Claude runs inside the pane's PTY, but on macOS the host app (Flock) is the
/// TCC subject for the microphone — so Flock must ship `NSMicrophoneUsageDescription`
/// (Info.plist) and the hardened-runtime `com.apple.security.device.audio-input`
/// entitlement. With those in place, macOS prompts automatically the first time
/// Claude touches the mic; this helper also lets the UI pre-request access.
enum VoiceMode {
    static var micStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Triggers the system microphone prompt. The prompt only appears once
    /// (while status is `.notDetermined`); afterwards the completion fires with
    /// the existing decision.
    static func requestMic(_ completion: ((Bool) -> Void)? = nil) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion?(granted) }
        }
    }

    static func openMicSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// UI entry point: request access if undetermined, otherwise open Settings
    /// when already denied (lets callers avoid importing AVFoundation).
    static func promptOrOpenSettings() {
        switch micStatus {
        case .denied, .restricted: openMicSettings()
        default: requestMic()
        }
    }
}
