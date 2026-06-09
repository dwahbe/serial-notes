import AppKit
import CoreAudio
import SystemAudioTap

/// System-audio ("Screen & System Audio Recording") TCC authorization for the
/// process tap, split into a read-only status check and a prompt trigger.
///
/// macOS exposes no *public* read-only status API for this permission. Inferring
/// it from whether a tap delivers audio does not work: building the tap +
/// aggregate succeeds regardless of the grant (the bundle already holds the mic
/// entitlement), and an authorized tap delivers *no* buffers while nothing is
/// playing — so buffer presence conflates "authorized" with "audio is currently
/// playing." Instead we read the actual decision through the private
/// `TCCAccessPreflight` (resolved via `dlsym`, mirroring the `SecTranslocate`
/// lookup in `MoveToApplications`) and fire the prompt separately by briefly
/// attempting a capture.
enum SystemAudioAuthStatus {
    case granted
    case denied
    case undetermined
}

/// Read the current system-audio capture authorization without prompting.
///
/// The process-tap grant lands under `kTCCServiceAudioCapture` (confirmed by
/// preflight on macOS 26); we also check `kTCCServiceScreenCapture` as a
/// belt-and-suspenders against the screen-&-system-audio grouping on other
/// versions, treating granted-on-either as granted. Returns `.undetermined` when
/// the private symbol can't be resolved, so callers fall back to firing the
/// prompt rather than hard-gating on a false negative.
///
/// Caveat: TCC caches a service's status per-process, so the running app that
/// *triggers* the prompt cannot observe the grant it just received — only a later
/// launch reads it. The setup guide accounts for this with a manual "Continue"
/// after firing the prompt (see `OnboardingFlowView`).
func systemAudioAuthorizationStatus() -> SystemAudioAuthStatus {
    guard let preflight = tccAccessPreflight else { return .undetermined }
    var sawDenied = false
    for service in ["kTCCServiceAudioCapture", "kTCCServiceScreenCapture"] {
        switch preflight(service as CFString, nil) {
        case 0: return .granted
        case 1: sawDenied = true
        default: break
        }
    }
    return sawDenied ? .denied : .undetermined
}

/// `int TCCAccessPreflight(CFStringRef service, CFDictionaryRef options)` —
/// returns 0 granted, 1 denied, 2 undetermined, without prompting. Private
/// TCC.framework symbol, resolved once via `RTLD_DEFAULT` (TCC is loaded into
/// every process). The service identifiers are passed as their literal
/// `"kTCCService…"` string values.
private typealias TCCAccessPreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
private let tccAccessPreflight: TCCAccessPreflightFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "TCCAccessPreflight") else {
        NSLog("[SerialNotes/Permission] TCCAccessPreflight unavailable")
        return nil
    }
    return unsafeBitCast(sym, to: TCCAccessPreflightFn.self)
}()

/// Fire the system-audio TCC prompt by briefly attempting a capture.
///
/// Building the tap + aggregate alone does **not** prompt — the authorization is
/// only evaluated once audio starts flowing — so we start an IO proc, hold it a
/// moment so TCC engages and presents the prompt, then tear everything down. The
/// grant decision is asynchronous; read it afterwards (e.g. when the app
/// reactivates) with `systemAudioAuthorizationStatus()`. No-ops if the tap API is
/// unavailable.
///
/// Deliberately a free function with no `AudioCaptureService` state: it can't
/// disturb a live capture's `tapInfo`. Callers must still avoid running it during
/// an active recording (the setup guide gates on
/// `RecordingState.hasActiveOrFinalizingSession` and suspends meeting detection
/// while open).
///
/// `nonisolated` on purpose — the tap create/start/stop/destroy can stall (and we
/// deliberately sleep briefly), so callers run it off the main actor
/// (`Task.detached`) to keep the UI responsive.
func triggerSystemAudioPrompt() {
    guard IsSystemAudioTapAvailable() else { return }
    let info = CreateSystemAudioTap()
    // DestroySystemAudioTap no-ops on zero IDs, so this is safe either way.
    defer { DestroySystemAudioTap(info) }
    guard info.aggregateDeviceID != 0 else {
        NSLog("[SerialNotes/Permission] tap/aggregate not created — tapID=\(info.tapID) agg=\(info.aggregateDeviceID)")
        return
    }

    var procID: AudioDeviceIOProcID?
    let queue = DispatchQueue(label: "com.serialnotes.permission-probe", qos: .userInitiated)
    let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, info.aggregateDeviceID, queue) { _, _, _, _, _ in }
    guard createStatus == noErr, let procID else {
        NSLog("[SerialNotes/Permission] AudioDeviceCreateIOProcIDWithBlock failed status=\(createStatus)")
        return
    }
    defer { AudioDeviceDestroyIOProcID(info.aggregateDeviceID, procID) }

    let startStatus = AudioDeviceStart(info.aggregateDeviceID, procID)
    guard startStatus == noErr else {
        NSLog("[SerialNotes/Permission] AudioDeviceStart failed status=\(startStatus)")
        return
    }
    // Hold the capture briefly so TCC engages and presents the prompt.
    Thread.sleep(forTimeInterval: 0.3)
    AudioDeviceStop(info.aggregateDeviceID, procID)
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
