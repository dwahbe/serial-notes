import Foundation

/// Identity of where a meeting should land in Notion, snapshotted into the
/// stop context at the stop press — never tokens. Credentials are loaded fresh
/// when the deferred export actually executes, so rotated tokens are never
/// retained in a snapshot.
struct NotionExportDestination: Equatable, Sendable {
    let workspaceID: String
    let pageID: String
}

/// The seam `RecordingState` sends finished meetings through — injected (and
/// faked in the lifecycle tests) rather than widening the static
/// `MeetingExporter` enum, which can't carry credentials or connection state.
/// Production conformer: `NotionConnection`.
@MainActor
protocol NotionSending: AnyObject {
    /// Snapshot for the stop context. nil unless currently connected — a
    /// stop with the toggle on but no live connection exports nothing.
    var exportDestination: NotionExportDestination? { get }

    /// Deliver one finished transcript. Fire-and-forget and best-effort,
    /// mirroring `MeetingExporter.export`: every failure is logged, never
    /// surfaced as a recording error — the on-disk transcript is the source
    /// of truth.
    func sendTranscript(at transcriptURL: URL, destination: NotionExportDestination)
}
