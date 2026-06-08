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
}
