import AppKit
import SystemAudioTap

/// Fire the "System Audio Recording Only" TCC prompt by briefly creating and
/// destroying a process tap, returning whether permission is granted.
///
/// There is no read-only status API for system-audio tap permission, so creating
/// the tap *is* the request — which is exactly the "drive the prompt inline"
/// behavior the setup guide wants. On success the tap is torn down immediately so
/// nothing keeps capturing.
///
/// Deliberately a free function with no `AudioCaptureService` state: it can't
/// disturb a live capture's `tapInfo`. Callers must still avoid running it during
/// an active recording (the setup guide gates on
/// `RecordingState.hasActiveOrFinalizingSession` and suspends meeting detection
/// while open).
///
/// `nonisolated` on purpose — creating/destroying the CoreAudio tap can stall, so
/// callers run it off the main actor (`Task.detached`) to keep the UI responsive.
func requestSystemAudioPermission() -> Bool {
    guard IsSystemAudioTapAvailable() else { return false }
    let info = CreateSystemAudioTap()
    let granted = info.tapID != 0 && info.aggregateDeviceID != 0
    // DestroySystemAudioTap no-ops on zero IDs, so this is safe either way.
    DestroySystemAudioTap(info)
    return granted
}

/// Open System Settings to the first of `candidates` that forms a valid URL,
/// falling back to the Settings root otherwise.
///
/// Caveat: `NSWorkspace.open` reports only that System Settings *launched*, not
/// that a pane anchor (e.g. `Privacy_Microphone`) resolved — macOS silently shows
/// a default pane for an unknown anchor. So this can't detect anchor drift across
/// releases; the candidate list only guards against a malformed URL string. Put
/// the most likely-correct anchor first.
@MainActor
func openSystemSettings(_ candidates: [String]) {
    for string in candidates {
        if let url = URL(string: string), NSWorkspace.shared.open(url) {
            return
        }
    }
    if let root = URL(string: "x-apple.systempreferences:") {
        NSWorkspace.shared.open(root)
    }
}
