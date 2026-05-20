import AppKit
import SwiftUI

@MainActor
final class MeetingBannerController {
    var onRecord: (@MainActor () -> Void)?
    var onDismiss: (@MainActor () -> Void)?
    var onEndStop: (@MainActor () -> Void)?
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

    func showEndPrompt(appName: String, remainingSeconds: Int) {
        if visiblePrompt == .end, let endPromptModel {
            endPromptModel.appName = appName
            endPromptModel.remainingSeconds = remainingSeconds
            repositionIfVisible()
            return
        }

        let model = MeetingEndPromptModel(appName: appName, remainingSeconds: remainingSeconds)
        endPromptModel = model
        let view = MeetingEndBannerView(
            model: model,
            onStop: { [weak self] in
                self?.hide()
                self?.onEndStop?()
            },
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
}

@Observable
private final class MeetingEndPromptModel {
    var appName: String
    var remainingSeconds: Int

    init(appName: String, remainingSeconds: Int) {
        self.appName = appName
        self.remainingSeconds = remainingSeconds
    }
}

private struct MeetingStartBannerView: View {
    let appName: String
    let onRecord: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void

    @State private var isHovering = false

    var body: some View {
        BannerPill(
            iconName: "waveform.circle.fill",
            iconColor: .black,
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
            .overlay(alignment: .topLeading) {
                dismissButton
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

    private var dismissButton: some View {
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
    }
}

private struct MeetingEndBannerView: View {
    @Bindable var model: MeetingEndPromptModel
    let onStop: @MainActor () -> Void
    let onKeepRecording: @MainActor () -> Void

    var body: some View {
        BannerPill(
            iconName: "stop.circle.fill",
            iconColor: Color(red: 0.78, green: 0.08, blue: 0.08),
            title: "\(model.appName) call ended",
            subtitle: "Stopping in \(model.remainingSeconds)s",
            backgroundColor: Color(red: 1.0, green: 0.965, blue: 0.955),
            strokeColor: Color(red: 0.78, green: 0.08, blue: 0.08).opacity(0.22),
            spacerMinLength: 8
        ) {
            Button(action: onKeepRecording) {
                Text("Keep Recording")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.black.opacity(0.76))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            Button(action: onStop) {
                Label("Stop Now", systemImage: "stop.fill")
                    .font(.caption.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color(red: 0.78, green: 0.08, blue: 0.08)))
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

private struct BannerPill<Trailing: View>: View {
    let iconName: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let backgroundColor: Color
    let strokeColor: Color
    var spacerMinLength: CGFloat = 10
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 28, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, iconColor)

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
