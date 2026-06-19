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
/// `01`–`04` numerals echo the marketing site's stepper; the whole list slides
/// up together as one smooth motion on appear (instantly under Reduce Motion,
/// matching the site's static fallback). The list syncs with the welcome stage: the `active` row
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Reveal as one gentle upward rise + fade. Driven by an explicit
        // `withAnimation` *inside* `onAppear` (which fires only after the rows are
        // laid out) rather than a persistent `.animation(_:value:)` modifier — the
        // latter let the rows' first-layout positioning get animated from the view
        // origin (top-leading), which read as a diagonal fly-in. Scoping the
        // animation to this one transaction keeps the motion a pure vertical
        // scroll-up; the `active`-row highlight stays on the caller's withAnimation.
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : 10)
        .onAppear {
            guard !revealed else { return }
            if reduceMotion {
                revealed = true
            } else {
                withAnimation(.easeOut(duration: 0.4)) { revealed = true }
            }
        }
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

/// Weak holder for a captured `NSWindow`, so a view can re-front its own window
/// later without retaining it.
@MainActor final class WeakWindow {
    weak var value: NSWindow?
}

/// Raise all of the app's visible windows above other apps for the duration of a
/// system permission prompt. `AVCaptureDevice.requestAccess` deactivates an
/// `.accessory` app, and macOS blocks it from reactivating for ~0.3s afterwards, so
/// every window would drop behind the previously-active app. Floating them keeps them
/// on top through that gap with no flash; `primary` stays topmost. Pair with
/// `settleAppWindows`. Call before the prompt.
@MainActor
func floatAppWindows(keeping primary: NSWindow?) {
    let top = primary?.sheetParent ?? primary
    for window in NSApp.windows where window.isVisible && window.canBecomeMain {
        window.level = .floating
        if window !== top { window.orderFrontRegardless() }
    }
    top?.orderFrontRegardless()
}

/// Reactivate and lower the floated windows back to normal — but only once the app is
/// actually active again, so they can't briefly drop behind during the post-prompt
/// gap. `primary` is left key/front.
@MainActor
func settleAppWindows(keeping primary: NSWindow?, attempt: Int = 0) {
    // Cooperative activation (macOS 14+): `activate()` is a request, but the system
    // grants it here because we triggered the prompt. The windows stay up via their
    // `.floating` level regardless; we only lower them back once actually active.
    NSApp.activate()
    guard NSApp.isActive || attempt >= 15 else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            settleAppWindows(keeping: primary, attempt: attempt + 1)
        }
        return
    }
    for window in NSApp.windows where window.canBecomeMain {
        window.level = .normal
    }
    (primary?.sheetParent ?? primary)?.makeKeyAndOrderFront(nil)
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
    /// Also re-front the window whenever the app reactivates — e.g. after a system
    /// permission prompt or a System Settings round-trip steals focus, which an
    /// `.accessory` app won't recover from on its own. Both Settings and the guide
    /// host prompts, so both opt in.
    var keepFrontOnReactivate = false
    /// Called with the hosting window once it exists, so a caller can capture it for
    /// later re-fronting (the Settings window does this).
    var onWindow: (@MainActor (NSWindow) -> Void)?

    func makeNSView(context: Context) -> NSView {
        BringToFrontView(keepFrontOnReactivate: keepFrontOnReactivate, onWindow: onWindow)
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? BringToFrontView)?.onWindow = onWindow
    }
}

private final class BringToFrontView: NSView {
    var onWindow: (@MainActor (NSWindow) -> Void)?

    init(keepFrontOnReactivate: Bool, onWindow: (@MainActor (NSWindow) -> Void)?) {
        self.onWindow = onWindow
        super.init(frame: .zero)
        if keepFrontOnReactivate {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appDidBecomeActive),
                name: NSApplication.didBecomeActiveNotification,
                object: nil
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // An `.accessory` (menu-bar-only) app fronts a window with `orderFrontRegardless()`
        // instead of flipping to `.regular`, keeping it out of the Dock + Cmd-Tab.
        onWindow?(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @objc private func appDidBecomeActive() {
        // Reactivated after a prompt / System Settings round-trip — re-raise the window
        // the app would otherwise leave buried. Raise only (no `makeKey`) so an open
        // menu-bar popover isn't dismissed, and skip it when the window is hidden.
        guard let window, window.isVisible else { return }
        window.orderFrontRegardless()
    }
}

/// Runs a teardown hook when the hosting `NSWindow` closes (e.g. the setup guide
/// resuming meeting detection).
struct WindowCloseChrome: NSViewRepresentable {
    /// Teardown to run on `willClose`.
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
    }
}
