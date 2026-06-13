import SwiftUI

/// The four "how it works" beats shown on the onboarding welcome screen. Each
/// case owns BOTH its caption (rendered by `NumberedStepList`) and its stage
/// frame, so the list and the mock can't drift apart — adding a beat is a
/// compile error until it has both a caption and a frame. Replaces the old
/// index-coupled `storyItems` array + `switch` with a swallowing `default:`.
enum WelcomeStoryBeat: Int, CaseIterable {
    case menuBar, detect, process, export

    /// Row caption in the numbered list alongside the stage.
    var caption: String {
        switch self {
        case .menuBar: "Lives in your menu bar."
        case .detect: "Detects your meetings and offers to record."
        case .process: "Transcribes and summarizes — all on-device."
        case .export: "Saves Markdown notes wherever you choose."
        }
    }

    /// The stage content for this beat. `.menuBar` has no content frame — its
    /// story is told by the menu-bar callout above the content zone.
    @ViewBuilder var stageFrame: some View {
        switch self {
        case .menuBar: Color.clear
        case .detect: BannerFrame()
        case .process: SummaryFrame()
        case .export: ExportFrame()
        }
    }
}

/// The animated mini-stage on the onboarding welcome step — a mock desktop that
/// walks the four `WelcomeStoryBeat`s in lockstep with the `NumberedStepList`
/// below it. Drawn in SwiftUI rather than bundled screenshots so it tracks
/// light/dark mode and can't go stale; the detect beat renders the real
/// `BannerPill` + `BannerCapsuleLabel`. The menu-bar mock uses real macOS 26
/// item ordering — it's a sibling of, not a pixel copy of, the marketing
/// site's "How it works" stage. Beat changes are animated by the caller's
/// `withAnimation` (see `OnboardingFlowView`), so this view carries no
/// `.animation(value:)` of its own.
struct WelcomeStageView: View {
    /// Active beat index. The parent owns cycling/selection (and the animation).
    let step: Int

    private var beat: WelcomeStoryBeat { WelcomeStoryBeat(rawValue: step) ?? .menuBar }

    var body: some View {
        VStack(spacing: 0) {
            StageMenuBar(highlighted: beat == .menuBar)
                // The beat-0 callout hangs below the bar, over the content zone.
                .zIndex(1)
            ZStack {
                // Conditional content swaps animate via the parent's
                // withAnimation transaction (default opacity transition).
                beat.stageFrame
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 170)
        .background(
            // Desktop wash — the site stage's soft top-left→bottom-right
            // gradient (#f7f7f8 → #e9e9eb), expressed in adaptive opacities.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.02), Color.primary.opacity(0.075)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Decorative — the numbered list alongside carries the same story as text.
        .accessibilityHidden(true)
    }
}

/// Mock macOS menu bar strip across the top of the stage. Item order matches a
/// real macOS 26 menu bar — third-party extras left of the system items: brand
/// glyph → battery → wifi → Control Center → clock. The clock is always 10:09
/// (watch-ad time). The brand glyph renders as a bare template glyph like the
/// real status item (which shows no chip until clicked); during the "lives in
/// your menu bar" beat it tints accent + glows and grows the "Right up here"
/// callout, drawing the eye without inventing a chip the real bar never shows.
private struct StageMenuBar: View {
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            brandGlyph
            Image(systemName: "battery.75percent")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Image(systemName: "wifi")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Image(systemName: "switch.2")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("10:09")
                // Absolute Color.primary (not hierarchical .primary) so the
                // clock renders at full label strength regardless of any
                // inherited foreground style.
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .kerning(-0.2)
                .foregroundStyle(Color.primary)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var brandGlyph: some View {
        BrandMark(strokeScale: 1.2)
            .frame(width: 15, height: 15)
            .foregroundStyle(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .shadow(color: highlighted ? Color.accentColor.opacity(0.55) : .clear, radius: 5)
            // Callout anchored to the glyph's TOP edge, then pushed below the
            // bar by a fixed offset — so it stays centered under the glyph
            // (no horizontal drift) AND longer copy grows downward without the
            // arrow creeping up into the bar (no height-dependent magic number).
            .overlay(alignment: .top) {
                if highlighted {
                    callout
                        .offset(y: 28)
                        .transition(.opacity)
                }
            }
    }

    /// Beat-0 callout: an up-arrow + label pointing at the brand glyph.
    /// `fixedSize` lets the text escape the 15pt glyph bounds.
    private var callout: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .semibold))
            Text("Right up here")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}

/// Beat 1 — the meeting-detected banner, top-trailing under the menu bar just
/// like the real `MeetingBannerController` placement. Renders the real
/// `BannerPill` + `BannerCapsuleLabel` sized from `MeetingBannerController`'s
/// own width constant, so the miniature can't drift from the real banner.
private struct BannerFrame: View {
    private static let scale: CGFloat = 0.72

    var body: some View {
        BannerPill(
            icon: .brand,
            title: "Meeting detected",
            subtitle: "Zoom",
            backgroundColor: .white,
            strokeColor: .black.opacity(0.08)
        ) {
            BannerCapsuleLabel(title: "Record", systemImage: "record.circle.fill")
                .padding(.trailing, 8)
                .padding(.vertical, 6)
        }
        .frame(width: MeetingBannerController.bannerWidth)
        .scaleEffect(Self.scale, anchor: .topTrailing)
        .allowsHitTesting(false)
        .padding(.top, 10)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

/// Beat 2 — a skeleton note card: summary lines + action-item checkboxes.
private struct SummaryFrame: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Summary", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
            skeletonBar(width: 170)
            skeletonBar(width: 130)
            Label("Action items", systemImage: "checklist")
                .font(.caption.weight(.semibold))
                .padding(.top, 3)
            actionRow(width: 120)
            actionRow(width: 95)
        }
        .padding(14)
        .frame(width: 230, alignment: .leading)
        .stageCard(cornerRadius: 10)
    }

    private func skeletonBar(width: CGFloat) -> some View {
        Capsule()
            .fill(Color.primary.opacity(0.12))
            .frame(width: width, height: 5)
    }

    private func actionRow(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.square")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            skeletonBar(width: width)
        }
    }
}

/// Beat 3 — the Markdown file landing in the chosen notes folder.
private struct ExportFrame: View {
    var body: some View {
        HStack(spacing: 10) {
            chip {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text("Team Sync.md")
                    .font(.system(size: 11, design: .monospaced))
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            chip {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Meeting Notes")
                    .font(.system(size: 11))
            }
        }
    }

    private func chip(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 6, content: content)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .stageCard(cornerRadius: 8)
    }
}

private extension View {
    /// Elevated card surface for the summary/export beats. Uses `.regularMaterial`
    /// (not a flat `.background` fill) so the card reads as *raised* against the
    /// desktop wash in BOTH light and dark mode — a plain background resolves
    /// darker than the wash in dark mode and reads as a recessed hole. The
    /// drop shadow carries elevation in light mode; the material carries it in
    /// dark, where black shadows are invisible.
    func stageCard(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(
            shape.fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        )
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
    }
}
