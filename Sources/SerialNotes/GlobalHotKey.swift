import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut backed by Carbon's `RegisterEventHotKey` —
/// the same mechanism Spotlight-style launchers use. It fires while any other
/// app is frontmost (full-screen included) and, unlike an `NSEvent` global
/// monitor, needs no Accessibility/Input Monitoring permission and no new
/// dependency.
///
/// While registered, the combo is *stolen* from the frontmost app system-wide,
/// so owners should register only while the shortcut is meaningful and release
/// it the moment it isn't (the notepad toggle is recording-scoped). Carbon hot
/// keys don't fire while macOS secure keyboard entry is active (password
/// fields, Terminal's Secure Keyboard Entry) — an accepted limitation.
@MainActor
final class GlobalHotKey {
    /// A key + Carbon modifier mask, plus the display string UI hints render —
    /// one value so the registered combo and its hint can't drift apart.
    struct KeyCombo {
        let keyCode: UInt32
        let carbonModifiers: UInt32
        let display: String

        /// ⌃⌘N — the notepad toggle. No stock app binds it, and the system's
        /// own neighbors on this chord (⌃⌘Space, ⌃⌘Q, ⌃⌘F) keep app menus
        /// away from bare ⌃⌘ combos.
        static let controlCommandN = KeyCombo(
            keyCode: UInt32(kVK_ANSI_N),
            carbonModifiers: UInt32(controlKey | cmdKey),
            display: "⌃⌘N"
        )
    }

    private let combo: KeyCombo
    private let onPress: @MainActor () -> Void
    private let hotKeyID: EventHotKeyID

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    var isRegistered: Bool { hotKeyRef != nil }

    private static let signature: FourCharCode =
        "SNhk".utf8.reduce(FourCharCode(0)) { ($0 << 8) + FourCharCode($1) }
    /// Distinguishes instances inside the shared-signature Carbon callback.
    private static var nextID: UInt32 = 1

    init(combo: KeyCombo, onPress: @escaping @MainActor () -> Void) {
        self.combo = combo
        self.onPress = onPress
        self.hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.nextID)
        Self.nextID += 1
    }

    /// Claim the combo system-wide. Idempotent. Failure is logged and leaves
    /// the hot key unregistered — the in-app buttons still work without it.
    func register() {
        guard hotKeyRef == nil else { return }
        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("[SerialNotes/GlobalHotKey] RegisterEventHotKey(%@) failed: %d",
                  combo.display, status)
            return
        }
        hotKeyRef = ref
    }

    /// Release the combo back to other apps. Idempotent.
    func unregister() {
        guard let ref = hotKeyRef else { return }
        UnregisterEventHotKey(ref)
        hotKeyRef = nil
    }

    /// Installed lazily on first register and kept for the object's lifetime.
    /// Instances are app-lifetime (owned by their controller), which is why the
    /// handler holds `self` unretained and there is no deinit teardown.
    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var pressedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard status == noErr else { return status }
                // Carbon dispatches these on the main thread — this asserts
                // the isolation rather than hopping.
                return MainActor.assumeIsolated {
                    Unmanaged<GlobalHotKey>.fromOpaque(userData)
                        .takeUnretainedValue()
                        .handlePress(pressedID)
                }
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        if status != noErr {
            NSLog("[SerialNotes/GlobalHotKey] InstallEventHandler failed: %d", status)
        }
    }

    private func handlePress(_ pressedID: EventHotKeyID) -> OSStatus {
        guard pressedID.signature == hotKeyID.signature,
              pressedID.id == hotKeyID.id,
              hotKeyRef != nil else {
            return OSStatus(eventNotHandledErr)
        }
        onPress()
        return noErr
    }
}
