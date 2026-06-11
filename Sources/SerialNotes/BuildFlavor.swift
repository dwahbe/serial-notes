import Foundation

extension Bundle {
    /// True for the locally-built dev flavor (`com.serialnotes.app.dev`).
    ///
    /// `build-app.sh` stamps the `.dev` bundle ID onto ad-hoc (local) builds so a
    /// `run.sh` build runs side-by-side with the downloaded production app —
    /// distinct bundle ID means distinct TCC permissions and a distinct
    /// UserDefaults domain, so the two never clobber each other. The menu bar tags
    /// this build "DEV" and Settings → About appends "· Dev" so the two icons are
    /// tellable apart.
    var isDevBuild: Bool {
        (bundleIdentifier ?? "").hasSuffix(".dev")
    }

    /// True when running inside `swift test`. The suites use Swift Testing, but
    /// SwiftPM still hosts them in an XCTest runner, so the class is loadable.
    /// This gates code with process-level side effects (relocating the bundle,
    /// `exit(0)` in the single-instance guard) — if the test harness ever stops
    /// linking XCTest, fix the detection here, in one place.
    var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }
}
