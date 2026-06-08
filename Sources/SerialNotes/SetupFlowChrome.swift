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
