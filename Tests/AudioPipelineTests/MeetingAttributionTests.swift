import Foundation
import Testing

@testable import SerialNotes

@Suite("Meeting Attribution")
struct MeetingAttributionTests {
    private func snapshot(
        coreAudioBundleIdentifier: String? = nil,
        appBundleIdentifier: String? = nil,
        appName: String? = nil,
        isRunningInput: Bool = false,
        isRunningOutput: Bool = false
    ) -> MeetingAudioProcessSnapshot {
        MeetingAudioProcessSnapshot(
            processObjectID: 1,
            pid: 100,
            coreAudioBundleIdentifier: coreAudioBundleIdentifier,
            appBundleIdentifier: appBundleIdentifier,
            appName: appName,
            isRunningInput: isRunningInput,
            isRunningOutput: isRunningOutput
        )
    }

    @Test("Idle Slack loses to a FaceTime call that actually holds the mic")
    func faceTimeWinsOverIdleSlack() {
        // The reported bug: Slack open but not in a call, then a FaceTime call
        // comes in. Only FaceTime is capturing input → it must win attribution.
        let slackIdle = snapshot(
            appBundleIdentifier: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            isRunningInput: false,
            isRunningOutput: true  // Slack may still be playing notification sounds
        )
        let faceTimeCall = snapshot(
            coreAudioBundleIdentifier: "com.apple.avconferenced",
            appName: "avconferenced",
            isRunningInput: true
        )

        let owners = MeetingDetectionService.meetingAppsCapturingInput(
            from: [slackIdle, faceTimeCall]
        )

        #expect(owners == ["com.apple.FaceTime"])
    }

    @Test("Exact bundle ID maps to its known app")
    func exactBundleIDMatch() {
        let zoom = snapshot(appBundleIdentifier: "us.zoom.xos", isRunningInput: true)
        #expect(MeetingDetectionService.knownMeetingAppBundleID(for: zoom) == "us.zoom.xos")
    }

    @Test("FaceTime helper process maps via the avconference substring")
    func faceTimeHelperSubstringMatch() {
        let helper = snapshot(coreAudioBundleIdentifier: "com.apple.avconferenced", isRunningInput: true)
        #expect(MeetingDetectionService.knownMeetingAppBundleID(for: helper) == "com.apple.FaceTime")
    }

    @Test("Display name resolves when bundle identifiers are absent")
    func displayNameFallback() {
        let process = snapshot(appName: "Zoom", isRunningInput: true)
        #expect(MeetingDetectionService.knownMeetingAppBundleID(for: process) == "us.zoom.xos")
    }

    @Test("Non-meeting processes are never owners")
    func nonMeetingProcessIgnored() {
        let music = snapshot(appBundleIdentifier: "com.apple.Music", appName: "Music", isRunningInput: true)
        #expect(MeetingDetectionService.knownMeetingAppBundleID(for: music) == nil)
        #expect(MeetingDetectionService.meetingAppsCapturingInput(from: [music]).isEmpty)
    }

    @Test("Output-only meeting audio does not count as capturing the mic")
    func outputOnlyNotCapturing() {
        let zoomOutputOnly = snapshot(
            appBundleIdentifier: "us.zoom.xos",
            isRunningInput: false,
            isRunningOutput: true
        )
        #expect(MeetingDetectionService.meetingAppsCapturingInput(from: [zoomOutputOnly]).isEmpty)
    }

    @Test("Two simultaneous capturers both surface as owners")
    func simultaneousCapturers() {
        let slackHuddle = snapshot(appBundleIdentifier: "com.tinyspeck.slackmacgap", isRunningInput: true)
        let zoomCall = snapshot(appBundleIdentifier: "us.zoom.xos", isRunningInput: true)
        let owners = MeetingDetectionService.meetingAppsCapturingInput(from: [slackHuddle, zoomCall])
        #expect(owners == ["com.tinyspeck.slackmacgap", "us.zoom.xos"])
    }

    @Test("Display-name match requires the whole name, not a substring")
    func displayNameRequiresWholeName() {
        // "Discord Overlay" must NOT resolve to Discord — only an exact name does.
        let overlay = snapshot(appName: "Discord Overlay", isRunningInput: true)
        #expect(MeetingDetectionService.knownMeetingAppBundleID(for: overlay) == nil)

        let exact = snapshot(appName: "Discord", isRunningInput: true)
        #expect(MeetingDetectionService.knownMeetingAppBundleID(for: exact) == "com.hnc.Discord")
    }

    @Test("Related bundle IDs group the Teams v1/v2 variants together")
    func relatedBundleIDsGroupTeamsVariants() {
        let association = MeetingRecordingAssociation(
            appName: "Microsoft Teams",
            bundleIdentifier: "com.microsoft.teams2",
            startedAt: Date()
        )
        let related = MeetingDetectionService.relatedBundleIDs(for: association)
        #expect(related.contains("com.microsoft.teams"))
        #expect(related.contains("com.microsoft.teams2"))
    }

    @Test("Related bundle IDs include an unknown association's own bundle ID")
    func relatedBundleIDsIncludeUnknownAssociation() {
        let association = MeetingRecordingAssociation(
            appName: "Some New App",
            bundleIdentifier: "com.example.newapp",
            startedAt: Date()
        )
        let related = MeetingDetectionService.relatedBundleIDs(for: association)
        #expect(related == ["com.example.newapp"])
    }
}
