import AVFoundation
import SwiftUI

/// Plays a single extracted speaker clip so the user can hear who "Person N" is.
/// Playback is audio *output* only — it never opens the mic, so meeting detection
/// does not need to be suspended around it.
@MainActor @Observable
final class ClipPlayer {
    private(set) var playingURL: URL?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    func isPlaying(_ url: URL) -> Bool { playingURL == url }

    func toggle(_ url: URL) {
        if playingURL == url { stop() } else { play(url) }
    }

    private func play(_ url: URL) {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        playingURL = url
        player.play()

        // No delegate (would need NSObject) — just clear state when the clip ends.
        let duration = player.duration
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.1))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        playingURL = nil
    }
}

/// Sheet that lets the user name the unrecognized speakers detected in one meeting.
/// Naming a speaker creates a reusable voice profile and relabels this meeting's
/// transcript. Reads the live session back from the store by URL so it reflects
/// each save without the caller threading state through.
struct SpeakerNamingView: View {
    let sessionURL: URL
    let store: MeetingSessionsStore
    let onClose: () -> Void

    @State private var player = ClipPlayer()

    private var session: MeetingSession? { store.session(at: sessionURL) }

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(width: 460, height: 540)
        .onDisappear { player.stop() }
    }

    @ViewBuilder
    private var content: some View {
        if let session, !session.nameableSpeakers.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(for: session)
                    ForEach(session.nameableSpeakers) { speaker in
                        SpeakerNamingRow(
                            session: session,
                            speaker: speaker,
                            store: store,
                            player: player
                        )
                    }
                }
                .padding(20)
            }
        } else {
            allDone
        }
    }

    private func header(for session: MeetingSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name the speakers")
                .font(.title2.weight(.semibold))
            Text("\(session.title) · \(session.pendingCount) to name")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Naming someone teaches Serial Notes their voice so it labels them by name in future meetings, and updates this meeting's transcript.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var allDone: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text("No one left to name")
                .font(.title3.weight(.semibold))
            Text("You can revisit this meeting anytime from Settings → Meetings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(session?.nameableSpeakers.isEmpty == false ? "Close" : "Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

private struct SpeakerNamingRow: View {
    let session: MeetingSession
    let speaker: DetectedSpeaker
    let store: MeetingSessionsStore
    let player: ClipPlayer

    @State private var nameDraft = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var clipURL: URL { session.clipURL(for: speaker) }
    private var isPlaying: Bool { player.isPlaying(clipURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                playButton
                VStack(alignment: .leading, spacing: 3) {
                    Text(speaker.label)
                        .font(.headline)
                    if !speaker.sampleText.isEmpty {
                        Text("“\(speaker.sampleText)”")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .italic()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("\(Int(speaker.totalSpeechSeconds.rounded()))s of speech")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                TextField("Their name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(save)
                Button("Skip", action: skip)
                    .buttonStyle(.bordered)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var playButton: some View {
        Button { player.toggle(clipURL) } label: {
            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Stop" : "Play this speaker's voice")
    }

    private func save() {
        do {
            try store.nameSpeaker(in: session, speaker: speaker, rawName: nameDraft)
            player.stop()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func skip() {
        do {
            player.stop()
            try store.skipSpeaker(in: session, speaker: speaker)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
