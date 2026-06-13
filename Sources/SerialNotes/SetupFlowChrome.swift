import AppKit
import SwiftUI

/// Shared chrome for the app's guided "setup" flows — voice enrollment
/// (`VoiceEnrollmentFlowView`) and first-run onboarding (`OnboardingFlowView`).
/// Kept `internal` so both flow views in the module reuse one source.

// MARK: - Step icon

/// A circled SF Symbol used at the top of a setup step.
struct SetupStepIcon: View {
    enum Style {
        /// Hairline ring around a tinted glyph (a neutral / in-progress step).
        case outline
        /// Solid wash behind the glyph (a resolved / highlighted step).
        case filled(Color)
    }

    let systemName: String
    var style: Style = .outline
    var glyphColor: Color = .accentColor
    var diameter: CGFloat = 140
    var glyphSize: CGFloat = 56
    var glyphWeight: Font.Weight = .regular

    var body: some View {
        ZStack {
            switch style {
            case .outline:
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
                    .frame(width: diameter, height: diameter)
            case .filled(let color):
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: diameter, height: diameter)
            }
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: glyphWeight))
                .foregroundStyle(glyphColor)
        }
    }
}

// MARK: - Bullet list

struct BulletList: View {
    let items: [(icon: String, text: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items, id: \.text) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(item.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Numbered step list

/// The "how it works" 1–2–3–4 on the onboarding welcome screen. Monospaced
/// `01`–`04` numerals echo the marketing site's stepper; rows fade in one
/// after another (all at once under Reduce Motion, matching the site's
/// static fallback). The list syncs with the welcome stage: the `active` row
/// highlights, and each row is a real `Button` (so VoiceOver and Full Keyboard
/// Access can drive the stage) that jumps to its beat via `onSelect`. Highlight
/// changes animate via the caller's `withAnimation`, not a local modifier.
struct NumberedStepList: View {
    let items: [String]
    /// Row highlighted in lockstep with `WelcomeStageView`.
    let active: Int
    /// Tap/activate handler — jumps the stage to the chosen beat.
    let onSelect: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // id: \.offset — identity is the row's position (which `active`
            // also keys off), so duplicate captions can't collide on identity.
            ForEach(Array(items.enumerated()), id: \.offset) { index, text in
                let isActive = active == index
                Button {
                    onSelect(index)
                } label: {
                    HStack(spacing: 12) {
                        Text(String(format: "%02d", index + 1))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                        Text(text)
                            .font(.callout)
                            .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 6)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.35).delay(Double(index) * 0.15),
                    value: revealed
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { revealed = true }
    }
}

// MARK: - Progress dots

struct PhraseDots: View {
    let count: Int
    let active: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i <= active ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: i == active ? 24 : 10, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: active)
            }
        }
    }
}

// MARK: - Window chrome

/// Restore `.accessory` activation policy when the *last* titled window goes
/// away — but only then. A menu-bar-only app flips to `.regular` to show a real
/// window (Settings or the setup guide); when it closes we must drop back to
/// `.accessory` or the app lingers in the Dock + Cmd-Tab. Excluding the window
/// that is *currently closing* (still `isVisible` during `willClose`) and
/// keeping `.regular` while any other titled window remains is what lets the
/// Settings window and the setup guide be open together without yanking the
/// policy out from under each other.
@MainActor
func restoreAccessoryIfNoOtherTitledWindow(excluding closing: NSWindow?) {
    let hasOtherTitledWindow = NSApp.windows.contains { window in
        window !== closing
            && window.isVisible
            && window.styleMask.contains(.titled)
    }
    if !hasOtherTitledWindow {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Pulls the hosting `NSWindow` above other apps' windows whenever it appears.
///
/// A menu-bar-only (`.accessory`) app that auto-opens a `Window` scene at launch
/// can have that window mounted *behind* whatever app is frontmost: `openWindow`
/// creates the window on a later runloop turn than the `NSApp.activate()` that
/// preceded it, so that activation finds no window to raise — and the cooperative
/// macOS 14+ `activate()` won't lift a fresh window over an already-active app.
/// Grabbing the window once it actually exists (in `viewDidMoveToWindow`) and
/// calling `orderFrontRegardless()` is what reliably surfaces the setup guide.
struct WindowBringToFront: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { BringToFrontView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class BringToFrontView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Surface + focus the window WITHOUT flipping to `.regular`. An `.accessory`
        // (menu-bar-only) app can front a window via `orderFrontRegardless()` — which
        // is what actually fixes the "mounts behind" problem — so we keep the app out
        // of the Dock + Cmd-Tab (its no-Dock-icon design) instead of parking a Dock
        // icon there for the whole setup flow.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

/// Watches the hosting `NSWindow` and runs teardown when it closes: an optional
/// caller hook (e.g. resume meeting detection) followed by the shared
/// activation-policy restore. Shared by the Settings window and the setup guide.
struct WindowCloseChrome: NSViewRepresentable {
    /// Extra teardown to run on `willClose`, before the activation-policy restore.
    var onClose: (@MainActor () -> Void)?

    func makeNSView(context: Context) -> NSView {
        WindowCloseObserver(onClose: onClose)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowCloseObserver)?.onClose = onClose
    }
}

private final class WindowCloseObserver: NSView {
    var onClose: (@MainActor () -> Void)?
    private var observedWindow: NSWindow?

    init(onClose: (@MainActor () -> Void)?) {
        self.onClose = onClose
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Drop any prior registration before re-registering — guards against
        // SwiftUI recreating the representable or the view being remounted on
        // a different window. Otherwise observers accumulate and `windowWillClose`
        // fires N times per close.
        if let prior = observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: prior
            )
            observedWindow = nil
        }

        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        observedWindow = window
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowWillClose(_ note: Notification) {
        onClose?()
        restoreAccessoryIfNoOtherTitledWindow(excluding: note.object as? NSWindow)
    }
}
