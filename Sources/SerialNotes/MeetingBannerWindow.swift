import AppKit
import SwiftUI

@MainActor
final class MeetingBannerController {
    var onRecord: (@MainActor () -> Void)?
    var onDismiss: (@MainActor () -> Void)?
    var onEndKeepRecording: (@MainActor () -> Void)?

    private let panel: NSPanel
    private var autoDismissTask: Task<Void, Never>?
    private var visiblePrompt: VisiblePrompt?
    private var endPromptModel: MeetingEndPromptModel?

    fileprivate static let bannerWidth: CGFloat = 340
    private static let screenInset: CGFloat = 14
    private static let autoDismissAfter: Duration = .seconds(15)
    private static let showAnimationDuration: CFTimeInterval = 0.22
    private static let hideAnimationDuration: CFTimeInterval = 0.18
    private static let slideOffset: CGFloat = 20

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.bannerWidth, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionIfVisible() }
        }
    }

    // Owned by SwiftUI @State at the app root, so this never deinits in practice.
    // Skip teardown rather than fight the nonisolated-deinit rules.

    func showStartPrompt(appName: String) {
        endPromptModel = nil
        let view = MeetingStartBannerView(
            appName: appName,
            onRecord: { [weak self] in
                self?.hide()
                self?.onRecord?()
            },
            onDismiss: { [weak self] in
                self?.hide()
                self?.onDismiss?()
            }
        )
        show(view: view, autoDismiss: true, prompt: .start)
    }

    /// Post-meeting prompt offering to name the unrecognized speakers a recording
    /// detected. Independent of the start/end prompts and the call-end state machine —
    /// the caller supplies the actions (open Settings → Meetings / dismiss). Auto-dismisses
    /// like the start prompt since it isn't time-sensitive (the session stays nameable
    /// from Settings).
    func showSpeakerNamingPrompt(
        count: Int,
        onName: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        endPromptModel = nil
        let view = MeetingNamingBannerView(
            count: count,
            onName: { [weak self] in
                self?.hide()
                onName()
            },
            onDismiss: { [weak self] in
                self?.hide()
                onDismiss()
            }
        )
        show(view: view, autoDismiss: true, prompt: .naming)
    }

    func showEndPrompt(appName: String) {
        if visiblePrompt == .end, let endPromptModel {
            endPromptModel.appName = appName
            repositionIfVisible()
            return
        }

        let model = MeetingEndPromptModel(appName: appName)
        endPromptModel = model
        let view = MeetingEndBannerView(
            model: model,
            onKeepRecording: { [weak self] in
                self?.hide()
                self?.onEndKeepRecording?()
            }
        )
        show(view: view, autoDismiss: false, prompt: .end)
    }

    private func show<V: View>(view: V, autoDismiss: Bool, prompt: VisiblePrompt) {
        let wasVisible = panel.isVisible
        visiblePrompt = prompt

        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.layoutIfNeeded()

        let target = targetFrame(for: hosting.fittingSize.height)

        if wasVisible {
            panel.setFrame(target, display: true, animate: false)
        } else {
            var start = target
            start.origin.y += Self.slideOffset
            panel.alphaValue = 0
            panel.setFrame(start, display: false)
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.showAnimationDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }

        if autoDismiss {
            scheduleAutoDismiss()
        } else {
            autoDismissTask?.cancel()
            autoDismissTask = nil
        }
    }

    func hide() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        visiblePrompt = nil
        endPromptModel = nil

        guard panel.isVisible else { return }

        var end = panel.frame
        end.origin.y += Self.slideOffset

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.hideAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(end, display: true)
        }, completionHandler: { [weak panel] in
            MainActor.assumeIsolated { panel?.orderOut(nil) }
        })
    }

    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.autoDismissAfter)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func repositionIfVisible() {
        guard panel.isVisible else { return }
        let height = panel.contentView?.fittingSize.height ?? panel.frame.height
        panel.setFrame(targetFrame(for: height), display: true)
    }

    private func targetFrame(for contentHeight: CGFloat) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else {
            return NSRect(x: 100, y: 100, width: Self.bannerWidth, height: contentHeight)
        }
        let height = max(contentHeight, 56)
        let x = visible.maxX - Self.bannerWidth - Self.screenInset
        let y = visible.maxY - height - Self.screenInset
        return NSRect(x: x, y: y, width: Self.bannerWidth, height: height)
    }
}

private enum VisiblePrompt {
    case start
    case end
    case naming
}

@Observable
private final class MeetingEndPromptModel {
    var appName: String

    init(appName: String) {
        self.appName = appName
    }
}

private struct MeetingStartBannerView: View {
    let appName: String
    let onRecord: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void

    var body: some View {
        BannerPill(
            icon: .brand,
            title: "Meeting detected",
            subtitle: appName,
            backgroundColor: .white,
            strokeColor: .black.opacity(0.08)
        ) {
            Button(action: onRecord) {
                Label("Record", systemImage: "record.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.black))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
        }
        .dismissableBannerChrome(onDismiss: onDismiss)
    }
}

private struct MeetingNamingBannerView: View {
    let count: Int
    let onName: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void

    private var subtitle: String {
        count == 1 ? "1 person to name" : "\(count) people to name"
    }

    var body: some View {
        BannerPill(
            icon: .symbol("person.2.wave.2.fill", color: .black),
            title: "New voices in this meeting",
            subtitle: subtitle,
            backgroundColor: .white,
            strokeColor: .black.opacity(0.08)
        ) {
            Button(action: onName) {
                Text("Name…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.black))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
        }
        .dismissableBannerChrome(onDismiss: onDismiss)
    }
}

/// The hover-reveal dismiss button + outer frame/padding shared by the start and naming
/// banners (the end-call banner has its own buttons and doesn't use this).
private struct DismissableBannerChrome: ViewModifier {
    let onDismiss: @MainActor () -> Void
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.75))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .offset(x: -6, y: -6)
                .opacity(isHovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
                .allowsHitTesting(isHovering)
            }
            .padding(.top, 8)
            .padding(.leading, 8)
            .frame(width: MeetingBannerController.bannerWidth, alignment: .leading)
            .preferredColorScheme(.light)
            .onHover { isHovering = $0 }
    }
}

private extension View {
    func dismissableBannerChrome(onDismiss: @escaping @MainActor () -> Void) -> some View {
        modifier(DismissableBannerChrome(onDismiss: onDismiss))
    }
}

private struct MeetingEndBannerView: View {
    @Bindable var model: MeetingEndPromptModel
    let onKeepRecording: @MainActor () -> Void

    // A calm green: the call ended normally and the recording is being saved —
    // nothing failed, so deliberately not red. The countdown is intentionally
    // hidden; the recording still auto-stops, but the user just sees a simple
    // "wrapping up" notice with one escape hatch.
    private static let accent = Color(red: 0.20, green: 0.56, blue: 0.30)

    var body: some View {
        BannerPill(
            icon: .symbol("checkmark.circle.fill", color: Self.accent),
            title: "\(model.appName) call ended",
            subtitle: "Wrapping up recording",
            backgroundColor: .white,
            strokeColor: .black.opacity(0.08),
            spacerMinLength: 8
        ) {
            Button(action: onKeepRecording) {
                Text("Keep Recording")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.black))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
        }
        .padding(.top, 8)
        .padding(.leading, 8)
        .frame(width: MeetingBannerController.bannerWidth, alignment: .leading)
        .preferredColorScheme(.light)
    }
}

/// The leading icon for a banner pill.
private enum BannerIcon {
    /// An SF Symbol rendered in palette mode (white primary + `color` secondary).
    case symbol(String, color: Color)
    /// The custom Serial Notes brand mark, filled (black disc + white waveform).
    case brand
}

private struct BannerPill<Trailing: View>: View {
    let icon: BannerIcon
    let title: String
    let subtitle: String
    let backgroundColor: Color
    let strokeColor: Color
    var spacerMinLength: CGFloat = 10
    @ViewBuilder let trailing: Trailing

    @ViewBuilder private var iconView: some View {
        switch icon {
        case let .symbol(name, color):
            Image(systemName: name)
                .font(.system(size: 28, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, color)
        case .brand:
            // Filled black mark mirrors the prior `waveform.circle.fill`
            // treatment (white waveform on a dark disc), but with our glyph.
            BrandFilledMark(discColor: .black)
                .frame(width: 28, height: 28)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            iconView

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.black.opacity(0.6))
                    .lineLimit(1)
            }
            .padding(.vertical, 14)

            Spacer(minLength: spacerMinLength)

            trailing
        }
        .padding(.leading, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(strokeColor, lineWidth: 1)
        )
    }
}
