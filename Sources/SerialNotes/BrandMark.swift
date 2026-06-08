import AppKit
import SwiftUI

// The canonical Serial Notes brand mark: a waveform inside a circle.
//
// This is the single Swift source of the glyph. Its geometry mirrors the
// website favicon (`site/public/favicon.svg`) — same 32×32 coordinate space —
// which the Logo component and the macOS app icon (`icon/AppIcon.svg`) also
// share. Keep these numbers in lockstep with favicon.svg; that file is the
// canonical source of truth (see DESIGN.md).
//
// The glyph is drawn in a 32-unit space and scaled to whatever frame it's given,
// so it stays crisp at any size. Per use case the *chrome* differs (the menu bar
// and popover show the bare glyph; the app icon/favicon wrap it in a tile) but
// the glyph itself never diverges.

/// The circle ring (center 16,16 · r 12 · stroke 2.0 in 32-space).
private struct BrandRing: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 32
        let center = CGPoint(x: rect.minX + 16 * s, y: rect.minY + 16 * s)
        let r = 12 * s
        return Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    }
}

/// The six waveform bars (stroke 1.6, round caps in 32-space). Thin bars with a
/// dynamic rhythm that decays to a tiny bar at the right end — an
/// SF-waveform-inspired silhouette: thin, elegant, generous padding to the ring.
private struct BrandBars: Shape {
    /// (x, yTop, yBottom) in the 32-unit space — verbatim from favicon.svg.
    static let bars: [(x: CGFloat, y1: CGFloat, y2: CGFloat)] = [
        (9.5, 13.75, 18.25),
        (12.1, 12, 20),
        (14.7, 10.75, 21.25),
        (17.3, 13.5, 18.5),
        (19.9, 12, 20),
        (22.5, 14.5, 17.5),
    ]

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 32
        var path = Path()
        for bar in Self.bars {
            path.move(to: CGPoint(x: rect.minX + bar.x * s, y: rect.minY + bar.y1 * s))
            path.addLine(to: CGPoint(x: rect.minX + bar.x * s, y: rect.minY + bar.y2 * s))
        }
        return path
    }
}

/// The idle mark — ring + bars, drawn in the current foreground style so it can
/// render as `.primary` in the popover or as a black template for the menu bar.
struct BrandMark: View {
    /// Multiplier on the canonical stroke widths; nudge above 1 if the strokes
    /// read thin at very small sizes.
    var strokeScale: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 32
            ZStack {
                BrandRing().stroke(style: StrokeStyle(lineWidth: 2.0 * s * strokeScale))
                BrandBars().stroke(style: StrokeStyle(lineWidth: 1.6 * s * strokeScale, lineCap: .round))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

extension Color {
    /// The "live" recording accent — a warm orange shared by the menu bar
    /// recording icon and the popover's recording dot, so the two stay in
    /// lockstep. (Replaces the old system-red; see DESIGN.md.)
    static let recordingLive = Color(red: 0.898, green: 0.510, blue: 0.180)
}

/// A filled variant — a solid disc with the waveform knocked in white. Used for
/// the menu bar **recording** icon (orange disc; the outline→filled shift
/// reads as a clear "live" state change) and the meeting-detected **banner**
/// (black disc, matching its bold aesthetic).
struct BrandFilledMark: View {
    var discColor: Color
    var barColor: Color = .white

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 32
            ZStack {
                // Disc diameter 26.0 (r 13.0) matches the idle ring's outer
                // silhouette (r 12 + half the 2.0 stroke), so the filled and
                // outline marks share a footprint. Centered at (16,16)·s.
                Circle()
                    .fill(discColor)
                    .frame(width: 26.0 * s, height: 26.0 * s)
                BrandBars()
                    .stroke(style: StrokeStyle(lineWidth: 1.6 * s, lineCap: .round))
                    .foregroundStyle(barColor)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Menu bar images

extension BrandMark {
    /// Point size of the menu bar glyph. The status bar scales to fit, but
    /// rendering at the natural size keeps the strokes optically correct.
    static let menuBarPointSize: CGFloat = 18

    /// Idle menu bar icon — a monochrome **template** image, so macOS tints it
    /// to match the menu bar (light/dark) and inverts it when the menu is open.
    @MainActor static let menuBarIdle: NSImage = makeMenuBarImage(
        AnyView(BrandMark().foregroundStyle(.black)),
        isTemplate: true
    )

    /// Recording menu bar icon — the orange "live" variant. Non-template so the
    /// orange + white survive (a template would flatten it to one tint).
    @MainActor static let menuBarRecording: NSImage = makeMenuBarImage(
        AnyView(BrandFilledMark(discColor: .recordingLive)),
        isTemplate: false
    )

    @MainActor private static func makeMenuBarImage(_ content: AnyView, isTemplate: Bool) -> NSImage {
        let renderer = ImageRenderer(
            content: content.frame(width: menuBarPointSize, height: menuBarPointSize)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: menuBarPointSize, height: menuBarPointSize))
        image.isTemplate = isTemplate
        return image
    }
}
