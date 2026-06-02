import Foundation
import Testing

@testable import SerialNotes

@Suite("Transcript Echo Suppression")
struct TranscriptEchoSuppressionTests {
    @Test("Remote speech echoed into mic is detected")
    func remoteSpeechEchoedIntoMicIsDetected() {
        let systemContext = """
        Okay, now that you know who we work with, what does that mean for who we look for? In terms of basic eligibility requirements, you need a minimum of three years of work experience.
        """
        let micText = """
        now that you know who we work with what does that mean for who we look for in terms of basic eligibility requirements you need a minimum of three years of work experience
        """

        #expect(TranscriptTextProcessing.isLikelyEcho(micText: micText, systemContext: systemContext))
    }

    @Test("Short backchannels are not suppressed")
    func shortBackchannelsAreNotSuppressed() {
        #expect(!TranscriptTextProcessing.isLikelyEcho(
            micText: "great thank you",
            systemContext: "Great, thank you."
        ))
    }

    @Test("Distinct user speech is not suppressed")
    func distinctUserSpeechIsNotSuppressed() {
        let systemContext = """
        The application deadline is the eighteenth of May, and interviews happen in June after the first review stage.
        """
        let micText = """
        I had a question about whether the practical interview will focus on finance experience or general problem solving
        """

        #expect(!TranscriptTextProcessing.isLikelyEcho(micText: micText, systemContext: systemContext))
    }
}

@Suite("Cross-Channel Echo Filter")
struct CrossChannelEchoFilterTests {
    private static let window: TimeInterval = 45
    private static let threshold = 0.7
    private static let minWords = 4

    private func filter(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        CrossChannelEchoFilter.filterEchoes(
            entries,
            windowSeconds: Self.window,
            containmentThreshold: Self.threshold,
            minWords: Self.minWords
        )
    }

    private func speakers(_ entries: [TranscriptEntry]) -> [String] {
        entries.sorted().map(\.speaker)
    }

    @Test("Remote speech bleeding into the mic as a phantom speaker is dropped")
    func micBleedPhantomSpeakerDropped() {
        // Mirrors the real transcript: "Voice 2" is the client echoing through the
        // laptop mic, duplicating what "Person 1" said on the system channel.
        let entries: [TranscriptEntry] = [
            .init(source: .mic, speaker: "You", text: "Okay, so now what we want to do is start the transfer to Cloudflare.", timestamp: 10),
            .init(source: .system, speaker: "Person 1", text: "This is Kyle's tiny business. Although he wouldn't like me saying that.", timestamp: 12),
            .init(source: .mic, speaker: "Voice 2", text: "This is Kyle's tiny business.", timestamp: 20),
            .init(source: .mic, speaker: "You", text: "Great, let's go to Safari and log into Cloudflare with Apple.", timestamp: 30),
        ]

        let kept = filter(entries)
        #expect(!kept.contains { $0.speaker == "Voice 2" })
        #expect(speakers(kept) == ["You", "Person 1", "You"])
    }

    @Test("Local user looping into the system channel as a phantom speaker is dropped")
    func systemLoopbackPhantomSpeakerDropped() {
        // Mirrors "Person 2" at call start: the user's own voice fed back into the
        // system capture, duplicating what "You" said on the mic channel.
        let entries: [TranscriptEntry] = [
            .init(source: .mic, speaker: "You", text: "Hello there. Let me see.", timestamp: 50),
            .init(source: .mic, speaker: "You", text: "Got it. Perfect. How are you?", timestamp: 55),
            .init(source: .system, speaker: "Person 2", text: "Hello there. Let me see. Got it.", timestamp: 52),
            .init(source: .system, speaker: "Person 1", text: "Good, good, just finished what I needed to do and got in a dog walk so Sasha is happy.", timestamp: 70),
        ]

        let kept = filter(entries)
        #expect(!kept.contains { $0.speaker == "Person 2" })
        #expect(kept.contains { $0.speaker == "Person 1" })
        #expect(kept.contains { $0.speaker == "You" })
    }

    @Test("A genuine second in-room speaker is preserved")
    func genuineSecondSpeakerPreserved() {
        // Non-dominant mic speaker, but their words do NOT appear on the system
        // channel — a real co-located participant, not echo. Must survive.
        let entries: [TranscriptEntry] = [
            .init(source: .mic, speaker: "You", text: "Let's walk through the domain transfer steps one at a time.", timestamp: 10),
            .init(source: .mic, speaker: "Voice 2", text: "I brought the quarterly revenue numbers for everyone to review.", timestamp: 25),
            .init(source: .system, speaker: "Person 1", text: "Sounds good, I can share my screen whenever you are ready.", timestamp: 15),
        ]

        let kept = filter(entries)
        #expect(kept.contains { $0.speaker == "Voice 2" })
        #expect(kept.count == entries.count)
    }

    @Test("The dominant speaker is never dropped even when quoting the other party")
    func dominantSpeakerNeverDropped() {
        // The user (dominant on mic) repeats the client's phrase back. Even though it
        // duplicates the system channel, a dominant-speaker line is always kept.
        let entries: [TranscriptEntry] = [
            .init(source: .system, speaker: "Person 1", text: "I would like to transfer Elizabeth Clearwater to Cloudflare today please.", timestamp: 10),
            .init(source: .mic, speaker: "You", text: "Transfer Elizabeth Clearwater to Cloudflare, got it.", timestamp: 14),
            .init(source: .mic, speaker: "You", text: "Okay, let me pull up your DNS records on my end now.", timestamp: 30),
        ]

        let kept = filter(entries)
        #expect(kept.count == entries.count)
    }

    @Test("A short non-dominant turn sharing only common filler is preserved")
    func shortFillerNotDroppedAsEcho() {
        // "Person 2" is a real, non-dominant remote participant giving a brief
        // acknowledgment. It shares the filler phrase "sounds good" with the local
        // user but is not a verbatim echo — only 2 of its 3 bigrams overlap
        // (containment 0.667). Under the old 0.5 threshold this genuine turn was
        // dropped; at 0.7 it survives while verbatim echoes (≈1.0) still go.
        let entries: [TranscriptEntry] = [
            .init(source: .mic, speaker: "You", text: "Okay, that sounds good to me, let's go ahead and proceed.", timestamp: 10),
            .init(source: .system, speaker: "Person 1", text: "Great, I will walk everyone through the migration plan step by step.", timestamp: 12),
            .init(source: .system, speaker: "Person 2", text: "Yeah, that sounds good.", timestamp: 18),
        ]

        let kept = filter(entries)
        #expect(kept.contains { $0.speaker == "Person 2" })
        #expect(kept.count == entries.count)
    }

    @Test("Echo outside the time window is not treated as a duplicate")
    func echoOutsideWindowKept() {
        let entries: [TranscriptEntry] = [
            .init(source: .system, speaker: "Person 1", text: "This is Kyle's tiny business and he runs it himself.", timestamp: 10),
            .init(source: .mic, speaker: "You", text: "Let me check the registrar settings for your domain now.", timestamp: 12),
            // Same words as Person 1 but ~3 minutes later — beyond the window.
            .init(source: .mic, speaker: "Voice 2", text: "This is Kyle's tiny business.", timestamp: 200),
        ]

        let kept = filter(entries)
        #expect(kept.contains { $0.speaker == "Voice 2" })
    }
}

@Suite("Mic Label Normalization")
struct MicLabelNormalizationTests {
    private func normalize(
        _ entries: [TranscriptEntry],
        collapseToPrimary: Bool,
        primaryName: String = "You",
        enrolled: Set<String> = []
    ) -> [TranscriptEntry] {
        CrossChannelEchoFilter.normalizeMicLabels(
            entries,
            collapseToPrimary: collapseToPrimary,
            primaryName: primaryName,
            enrolledMicNames: enrolled
        )
    }

    @Test("On a remote call a surviving phantom mic speaker is relabeled You")
    func phantomMicSpeakerCollapsedOnRemoteCall() {
        let entries: [TranscriptEntry] = [
            .init(source: .mic, speaker: "You", text: "Let's start the domain transfer.", timestamp: 10),
            .init(source: .mic, speaker: "Voice 2", text: "Dynamic gallery, gallery.", timestamp: 20),
            .init(source: .system, speaker: "Person 1", text: "Okay, I see the share button now.", timestamp: 15),
        ]

        let kept = normalize(entries, collapseToPrimary: true)
        #expect(!kept.contains { $0.speaker.hasPrefix("Voice") })
        #expect(kept.filter { $0.source == .mic }.allSatisfy { $0.speaker == "You" })
        // System labels are never touched.
        #expect(kept.contains { $0.source == .system && $0.speaker == "Person 1" })
    }

    @Test("A preferred name is used as the collapse target instead of You")
    func preferredNameUsedAsCollapseTarget() {
        let entries: [TranscriptEntry] = [
            .init(source: .mic, speaker: "Dylan", text: "Let's start the domain transfer.", timestamp: 10),
            .init(source: .mic, speaker: "Voice 2", text: "Dynamic gallery, gallery.", timestamp: 20),
            .init(source: .system, speaker: "Person 1", text: "Okay, I see the share button now.", timestamp: 15),
        ]

        // "Dylan" is both the enrolled label and the collapse target, so the whole
        // mic channel resolves to "Dylan" — no "You" and no phantom "Voice N".
        let kept = normalize(entries, collapseToPrimary: true, primaryName: "Dylan", enrolled: ["Dylan"])
        #expect(kept.filter { $0.source == .mic }.allSatisfy { $0.speaker == "Dylan" })
        #expect(!kept.contains { $0.speaker == "You" })
        #expect(!kept.contains { $0.speaker.hasPrefix("Voice") })
    }

    @Test("In-person recording keeps distinct mic speakers")
    func inPersonKeepsDistinctMicSpeakers() {
        let entries: [TranscriptEntry] = [
            .init(source: .mic, speaker: "You", text: "Let's review the quarterly numbers.", timestamp: 10),
            .init(source: .mic, speaker: "Voice 2", text: "I brought the revenue figures.", timestamp: 20),
        ]

        // No system audio this session → collapseToPrimary is false.
        let kept = normalize(entries, collapseToPrimary: false)
        #expect(kept.contains { $0.speaker == "Voice 2" })
    }

    @Test("An enrolled mic name is preserved through the collapse")
    func enrolledMicNamePreserved() {
        let entries: [TranscriptEntry] = [
            .init(source: .mic, speaker: "Dylan", text: "Let's start the transfer.", timestamp: 10),
            .init(source: .mic, speaker: "Voice 2", text: "Dynamic gallery, gallery.", timestamp: 20),
            .init(source: .system, speaker: "Person 1", text: "Okay, got it.", timestamp: 15),
        ]

        let kept = normalize(entries, collapseToPrimary: true, enrolled: ["Dylan"])
        #expect(kept.contains { $0.speaker == "Dylan" })
        #expect(!kept.contains { $0.speaker.hasPrefix("Voice") })
        #expect(kept.contains { $0.source == .mic && $0.speaker == "You" })
    }
}
