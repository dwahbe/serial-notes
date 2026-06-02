# CLAUDE.md

## What is this?

Serial Notes — a menu bar-only macOS app that captures meeting audio, transcribes locally, and exports Markdown. See `README.md` for full product context.

## Build & Run

```bash
./scripts/run.sh          # build + wrap as .app + launch (dev loop)
./scripts/build-app.sh    # build + wrap only, don't launch
swift test                # unit tests (SwiftPM — no .app needed)
```

**Why scripts, not `swift run`:** SwiftPM executable targets compile to a raw
binary. macOS LaunchServices-gated APIs (Login Items, URL schemes,
`UNUserNotificationCenter`, TCC prompts tied to a bundle ID) require the
binary to live inside a proper `.app` bundle with a sibling
`Contents/Info.plist`. The scripts build the SwiftPM binary, wrap it into
`.build/SerialNotes.app`, ad-hoc sign it with entitlements, and register it
with LaunchServices. This mirrors the pattern used by
[CodexBar](https://github.com/steipete/CodexBar) and other shipping
SwiftPM-native menu bar apps.

**Never use `swift run`** — it produces a raw binary that crashes on any
LaunchServices-gated call (`bundleProxyForCurrentProcess is nil`).

**Xcode usage:** open `Package.swift` in Xcode as an editor only. To run,
invoke `./scripts/run.sh` from a terminal. Do not press Run in Xcode — it
builds a raw binary in DerivedData that registers under the same bundle ID
as the wrapped `.app`, leading to duplicate menu bar icons and traced
(frozen) processes. `run.sh` purges any DerivedData build it finds.

Requires **Xcode 26+** and **macOS 26+**. Swift tools version 6.2.

## Releases

```bash
./scripts/release.sh 0.2.0           # build + zip + tag + GitHub pre-release
./scripts/release.sh 1.0.0 --stable  # same, but a full (non-pre) release
```

- **Versioning:** SemVer. While in beta we stay on `0.x.y` — major version `0`
  is itself the "beta" signal (the Settings → About row and the GitHub
  pre-release flag both derive from it; no `-beta` strings to maintain). Bump
  to `1.0.0 --stable` to leave beta.
- **Single source of truth = the git tag.** `build-app.sh` stamps
  `CFBundleShortVersionString` from the latest tag (`vX.Y.Z` → `X.Y.Z`) and
  `CFBundleVersion` from the commit count, via `PlistBuddy`, before signing.
  The keys in `Info.plist` are only fallbacks for builds made outside a git
  checkout. `release.sh` pins `MARKETING_VERSION` so the artifact always
  matches the tag it creates.
- **Release notes** are GitHub-Releases-native: `--generate-notes` builds them
  from merged PRs since the last tag, grouped by label per `.github/release.yml`.
  There is intentionally no separate `CHANGELOG.md` to double-maintain — the
  Releases page is the canonical changelog.
- **Signing / distribution:** ad-hoc by default. To ship a build others can
  open without Gatekeeper friction, export
  `SIGN_IDENTITY="Developer ID Application: … (TEAMID)"` (hardened runtime is
  already on) and add a `notarytool submit --wait` + `stapler staple` step to
  `release.sh` after the zip. Until then, a downloaded `.app` is quarantined
  and testers must `xattr -dr com.apple.quarantine SerialNotes.app`.

## Project Structure

```
Package.swift              # SwiftPM manifest (executable + tests + ObjC module)
scripts/
  build-app.sh             # swift build → wrap into .app → stamp version → codesign → lsregister
  run.sh                   # kill existing instance → build-app.sh → open .app
  release.sh               # build → zip → git tag → gh (pre-)release w/ auto notes
Sources/
  SerialNotes/             # Main app target (SwiftUI executable)
    SerialNotesApp.swift              # Entry point, MenuBarExtra + Settings scenes,
                                      #   kicks off model download at launch,
                                      #   wires detector → recording stop callbacks,
                                      #   drains finalization on app quit
    MenuBarView.swift                 # Popover UI (idle + recording states)
    SettingsView.swift                # Settings window (General + Voices tabs)
    RecordingState.swift              # Observable recording state + timer +
                                      #   stop(reason:) / stopAndWait / finalizationTask
    StorageSettings.swift             # Storage location + saveAudioFiles toggle persistence
    SummarySettings.swift             # Summary + action-items toggle persistence
    MeetingSettings.swift             # Auto-stop-after-call-ends toggle (on by default)
    IdentitySettings.swift            # User's optional preferred name (replaces "You"
                                      #   in transcripts); standalone, no enrollment needed
    AudioCaptureService.swift         # Audio capture (process tap + SCK fallback)
    TranscriptionService.swift        # FluidAudio ASR + diarizer actor,
                                      #   applies punctuation via TranscriptRewriter,
                                      #   splices summary + action items at endSession
    EchoSuppressionContext.swift      # TranscriptEntry value type + n-gram echo
                                      #   suppression context used by the streaming
                                      #   pipeline, plus CrossChannelEchoFilter — the
                                      #   dominance-aware cross-channel echo remover +
                                      #   mic→primary-name (preferred name / "You")
                                      #   label collapse used by the
                                      #   final-render pass
    FinalTranscriptSegmenter.swift    # Pure-function segmenter that breaks the
                                      #   high-accuracy ASRResult into
                                      #   timestamped chunks via token timings
    TranscriptRewriter.swift          # Foundation Models on-device LLM that restores
                                      #   punctuation + capitalization per EOU utterance,
                                      #   with a heuristic fallback when AI unavailable.
                                      #   Also home to the shared withTimeout helper
                                      #   used by the summarizer.
    TranscriptSummarizer.swift        # Foundation Models on-device LLM that generates
                                      #   the meeting summary + action items from the
                                      #   finalized transcript at session end; returns
                                      #   nil factory when Apple Intelligence is off
    TranscriptFormatter.swift         # Markdown transcript rendering (header, entries,
                                      #   summary + action-items sections,
                                      #   summaryInput(from:cutoff:) for end-of-call trim)
    ModelDownloadState.swift          # Observable status for model prefetch
    MeetingDetectionService.swift     # Fuses NSWorkspace + CoreAudio mic signal;
                                      #   owns call-end monitoring + state machine
    MeetingAudioActivityMonitor.swift # Per-process CoreAudio listener
                                      #   (kAudioProcessPropertyIsRunningInput/Output)
                                      #   for detecting when the associated meeting
                                      #   app stops producing audio
    MeetingAudioTypes.swift           # Boundary value types: MeetingRecordingAssociation,
                                      #   MeetingAudioProcessSnapshot,
                                      #   MeetingAudioActivitySnapshot,
                                      #   MeetingAudioActivityState,
                                      #   MeetingSessionDiagnostics
    CallEndStateMachine.swift         # Pure-reducer state machine for the call-end
                                      #   timeline (monitoring → inactiveGrace →
                                      #   prompting → suppressed) emitting [Effect]
                                      #   cases consumed by MeetingDetectionService
    RecordingStopReason.swift         # Stop-reason enum (.manual / .callEndedAuto /
                                      #   .callEndedUserConfirmed / .appQuit) +
                                      #   MeetingCallEndContext (carries inactiveAt
                                      #   used as the summary cutoff)
    MeetingBannerWindow.swift         # Floating NSPanel banner (start prompt +
                                      #   call-ended prompt modes)
    VoiceProfile.swift                # Profile data type (.you / .other)
    VoiceProfileStore.swift           # On-disk profile store (JSON + WAV pairs)
    VoiceEnrollmentRecorder.swift     # @Observable mic recorder used by enrollment
    VoiceEnrollmentFlowView.swift     # Face-ID-style guided enrollment flow
    Info.plist                        # Real bundle plist (copied into .app)
    SerialNotes.entitlements          # Applied via codesign in build-app.sh
  SystemAudioTap/          # ObjC module wrapping CoreAudio tap API
Tests/
  AudioPipelineTests/      # Swift test suites (swift test — no .app needed).
                           #   Tap C-API + mic-engine + SCK + transcription
                           #   suites pass under `swift test`. The system-audio
                           #   IOProc end-to-end test is gated behind
                           #   SERIAL_AUDIO_INTEGRATION_TEST=1 because TCC
                           #   denies aggregate-device creation to a
                           #   non-bundled binary.
    AudioPipelineTests.swift              # C tap API, mic engine, SCK, IOProc integration
    CATapIntrospection.swift              # Tap descriptor + API roundtrip
    TapDeviceTests.swift                  # Process-tap device introspection
    TranscriptionTests.swift              # FluidAudio ASR + diarizer smoke tests
    TranscriptionErrorTests.swift         # Transcription error-path tests
    TranscriptRewriterTests.swift         # Heuristic rewriter + FM smoke test
                                          #   (FM smoke test gated by SERIAL_FM_TEST=1)
    TranscriptSummarizerTests.swift       # Formatter + chunking + fake-summarizer wiring
                                          #   tests + FM smoke test (gated by SERIAL_FM_TEST=1)
    TranscriptFormatterTests.swift        # Markdown rendering + summary-cutoff tests
    TranscriptEchoSuppressionTests.swift  # n-gram echo suppression unit tests
    FinalTranscriptSegmenterTests.swift   # Token-timing segmenter unit tests
    CallEndStateMachineTests.swift        # Pure-reducer state machine unit tests
    MeetingAudioActivityMonitorTests.swift # CoreAudio process-list monitor smoke tests
    MeetingSettingsTests.swift            # Auto-stop toggle persistence
```

## Architecture

- **SwiftUI** with `@Observable` (Swift 6 concurrency). All UI types are `@MainActor`.
- **Two capture paths**: `AudioCaptureService` tries a CoreAudio process tap first (ObjC `SystemAudioTap` module), falls back to ScreenCaptureKit.
- **System audio uses raw HAL IOProc, not AVAudioEngine**: the system path runs `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart` directly on the tap-aggregate device. Do **not** revert to `AVAudioEngine.inputNode.installTap` — it goes through AUHAL, and AUHAL on a tap-aggregate device silently delivers zero buffers (engine reports running, IO proc gets created, no buffers ever fire the tap callback). The mic path stays on AVAudioEngine because the mic is a regular input device, not an aggregate.
- **Aggregate device construction**: `SystemAudioTap.m` builds a private aggregate containing the **default output device as `kAudioAggregateDeviceMainSubDeviceKey` + `kAudioAggregateDeviceSubDeviceListKey`** plus the process tap as a sub-tap. The output device is required as the clock master — a tap-only aggregate has no clock and its IO proc never fires. The output's normal audio routing isn't disturbed; the tap just observes what's sent to it.
- **State**: `RecordingState` owns the `AudioCaptureService` and drives the UI. `StorageSettings` manages the output directory via UserDefaults. `VoiceProfileStore` holds saved enrollment profiles.
- **Transcription**: [FluidAudio](https://github.com/FluidInference/FluidAudio) Parakeet streaming ASR + LS-EEND DIHARD III diarizer, both on-device. Models are cached in `~/Library/Application Support/FluidAudio/Models/`. Download is kicked off at app launch from `SerialNotesApp.init` (not popover open) so the banner can record without requiring the user to open the popover first. `RecordingState.start()` also awaits `downloadModelsIfNeeded()` as a safety net — idempotent, so no double-download.
- **Punctuation + capitalization**: Parakeet emits raw lowercase with no punctuation. `TranscriptRewriter` closes the gap: each EOU callback in `TranscriptionService` spawns a detached rewrite task; the task awaits the rewriter and then appends the entry to `pendingEntries` on the actor. The production implementation (`FoundationModelsRewriter`) is an actor around Apple's on-device `LanguageModelSession` (macOS 26+) using a `@Generable` schema + 2s timeout + strict word-equality guard (lowercased-alphanumeric compare) to reject hallucinations. When Apple Intelligence is unavailable (disabled, ineligible hardware, model not ready) the factory returns `HeuristicRewriter` — capitalize first char, append `.` if missing. The rewriter only runs on finalized utterances. Detached rewrite tasks are tracked in `rewriteTasks`; `endSession` races their natural drain against a 5s hard timeout and cancels any still-pending so a wedged on-device FM call can't hang the user's "Stop" press. Cancelled tasks short-circuit before writing back to the actor.
- **Summary + action items**: `TranscriptSummarizer` is **constructed at session start** when either toggle is on, and its two `LanguageModelSession`s are prewarmed in parallel during the recording so the first call at session end doesn't pay ~200–500ms of cold-start each. The actual summarize call still runs once inside `TranscriptionService.endSession()` after both the streaming and high-accuracy paths have written their final file to disk. `FoundationModelsSummarizer` wraps two sessions (one per task) with separate `@Generable` schemas (`MeetingSummary`, `GeneratedActionItemList`), a 15s per-call timeout, single-pass under 2500 words / map-reduce above, and dedup + sanitization on the output. The factory returns `nil` when Apple Intelligence is unavailable — there is **no heuristic fallback** because a fabricated summary is worse than none. The splice reads the finalized `transcript.md` back, inserts `## Summary` + `## Action items` sections between the header and the first speaker entry, and writes the file atomically. The splice is idempotent: if `## Summary` or `## Action items` already appears in the body it returns early rather than re-running FM and prepending a second set. If the user toggles summary on after recording starts, the splice falls back to lazy construction. Both sections are toggled independently via `SummarySettings` (General tab + menu bar popover, both on by default).
- **Summary cutoff for auto-stopped recordings**: when a recording stops via `.callEndedAuto` or `.callEndedUserConfirmed`, the `MeetingCallEndContext.inactiveAt` timestamp is threaded through `TranscriptionService.endSession(summaryCutoff:)` into `TranscriptFormatter.summaryInput(from:cutoff:)`. Entries with a timestamp at or beyond the cutoff are excluded from the summary input only — they remain in the on-disk transcript. This keeps post-call hallway audio out of the summary without losing it. Manual stops pass `nil` (no cutoff).
- **Voice enrollment**: `VoiceProfileStore` persists profiles to `~/Library/Application Support/SerialNotes/voices/` as `<uuid>.json` + `<uuid>.wav` pairs. `VoiceEnrollmentRecorder` captures a short mic clip with per-phrase silence detection (RMS threshold + hangover) and advances through three phrases. `VoiceEnrollmentFlowView` is the Face-ID-style guided UI. Decoded WAV samples are cached in `VoiceProfileStore` after first read (invalidated by `reload()`, which runs after every save / rename / delete). On session start, `RecordingState` hands enrollment clips, a `SummarySettings.Snapshot`, and the preferred name to `TranscriptionService.startSession(enrollments:summarySettings:micPrimaryName:)`, which primes each diarizer so matching voices get named instead of labeled `You` / `Person N`, and constructs + prewarms the summarizer if needed.
- **Preferred name**: `IdentitySettings.yourName` (UserDefaults, set in Settings → Voices) is the user's *optional* display name — independent of voice enrollment, so it works even with no recorded sample. `IdentitySettings.micDisplayName` (the trimmed name, or `You` when unset) is threaded through `RecordingState.start()` into `startSession(micPrimaryName:)` and becomes the single label for the user's mic voice in three places that must agree: the streaming default mic label (`labelForSpeaker`), the `.you` diarizer enrollment label (set in `loadEnrollments` so matched segments carry the same name), and the final-render `CrossChannelEchoFilter.normalizeMicLabels` collapse target. The whole mic side therefore reads as the preferred name instead of `You`. The enrollment flow's naming step pre-fills from / writes back to the same setting.
- **Detection suspend/resume**: any code that holds the mic for non-meeting purposes (currently just `VoiceEnrollmentRecorder`) must call `MeetingDetectionService.suspendDetection()` before engine start and `resumeDetection()` on stop. Otherwise enrollment audio would false-fire the "meeting detected" banner. Wiring lives in `SettingsView`'s `VoicesSettingsTab.onAppear`.
- **Settings scene**: a standard SwiftUI `Settings { … }` scene (not a bespoke window). `SettingsWindowChrome` observes the hosting NSWindow's `willCloseNotification` and restores `NSApp.setActivationPolicy(.accessory)`; without this, clicking the gear flips the app to `.regular` and leaves it visible in Dock + Cmd-Tab after the window closes.
- **Meeting detection**: `MeetingDetectionService` fuses two local signals — NSWorkspace launch/terminate/activate notifications (known meeting app bundle IDs) and a CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` listener on the default input device (mic in use). Known meeting apps are encoded in `knownMeetingApps: [String: KnownMeetingApp]` — each entry pairs the visible bundle ID with a `displayName` and a list of `coreAudioBundleSubstrings` used by the audio-activity monitor's loose matcher. Single source of truth — adding a new meeting app means adding one row. Currently: Zoom, Microsoft Teams (v1 + v2), FaceTime, Slack, Webex, Discord.
- **Detection state machine — sticky attribution**: once the mic goes active, the service locks onto one bundle ID (chosen via frontmost → most-recently-activated → alphabetical fallback — never `Set.first`, which is non-deterministic). While the mic stays continuously active, frontmost/activation changes do **not** re-attribute. This prevents "Slack call detected" when Zoom warm-holds the mic at end-of-call and the user switches to Slack. If the locked app terminates mid-window, detection clears but does not hunt for a replacement. Mic inactivity is the only reset.
- **Dismiss / Stop-while-in-call**: both flip a `userRejectedThisWindow` flag so no further prompts fire until the mic cycles (signals a new call). Stopping a recording mid-call implicitly counts as dismiss — we don't re-prompt the user who just chose to stop.
- **Auto-end recording**: when a recording starts and is associated with a detected meeting app (the locked bundle ID at recording-start time), `MeetingDetectionService` spins up `MeetingAudioActivityMonitor` against that app. The monitor installs a `kAudioHardwarePropertyProcessObjectList` listener and per-process `kAudioProcessPropertyIsRunningInput/Output` listeners on every matched process (matched by exact bundle ID + the `coreAudioBundleSubstrings` loose fallback). Activity changes feed `CallEndStateMachine`, a pure reducer with phases `monitoring → inactiveGrace → prompting → suppressed` and effects routed back through `handleCallEndEffects`. Defaults: **10s inactive grace**, **20s countdown**. The end-call banner shows a "Keep Recording" / "Stop Now" choice. Auto-stop fires `.callEndedAuto`; the user's "Stop Now" fires `.callEndedUserConfirmed`; both carry a `MeetingCallEndContext` whose `inactiveAt` drives the summary cutoff. "Keep Recording" puts the machine in `.suppressed` and tears the monitor down — no second prompt fires for that recording. The auto-stop suppression is **per-recording** and lives in the state machine; it is intentionally distinct from the per-mic-cycle `userRejectedThisWindow` flag, which governs the start-prompt machinery. Manual recordings (no detected association) and recordings on machines where Apple Intelligence has not made the per-process API available skip auto-stop entirely. The toggle is `MeetingSettings.autoStopAfterCallEnds` (on by default; no Settings UI in v1).
- **Stop reasons**: `RecordingState.stop(reason: RecordingStopReason = .manual)` accepts `.manual`, `.callEndedAuto(MeetingCallEndContext)`, `.callEndedUserConfirmed(MeetingCallEndContext)`, and `.appQuit`. The reason is written to `session.json`. `stop(reason:)` is fire-and-forget; the synchronous variant `stopAndWait(reason:)` (used by `applicationShouldTerminate`) awaits a shared `finalizationTask` so app-quit drains transcript finalization + summary splice before the process exits. The `MeetingCallEndContext.inactiveAt` is the only cutoff signal used by the summary input — keep all summary-cutoff logic flowing through `RecordingStopReason.summaryCutoffDate` rather than reaching into state machine internals.
- **Prompt surface**: `MeetingBannerController` renders a custom borderless `NSPanel` (Granola-style) in the top-right of the active screen. `.statusBar` level + `canJoinAllSpaces + fullScreenAuxiliary` collection so it floats over fullscreen Zoom and follows spaces. Two modes: the **start prompt** ("Meeting detected", auto-dismisses after 15s) and the **end-call prompt** ("…call ended" with countdown; dismisses only on activity resume, user action, recording stop, or countdown completion — never on a timer).
- **No networking**. Everything runs locally. Exceptions: FluidAudio model downloads from Hugging Face on first launch, and Apple's on-device Foundation Models (which may pull its base model through system channels outside the app's control).

## Design

See **[DESIGN.md](DESIGN.md)** for all frontend and design decisions (Liquid Glass rules, layout constants, typography, icon conventions).

## Conventions

- Target macOS 26 APIs freely — no backwards compatibility needed
- `Info.plist` is a real file copied into `.app/Contents/` by `build-app.sh` (no linker `__info_plist` hack)
- `SerialNotes.entitlements` is applied via `codesign --entitlements` in `build-app.sh` — currently only `com.apple.security.device.audio-input`
- Bundle ID: `com.serialnotes.app`
- Audio output: timestamped session directories containing `system.wav` + `mic.wav` (48kHz mono float32) alongside a streaming `transcript.md` and a `session.json` sidecar (records `stopReason`, summary cutoff, meeting diagnostics). The WAVs are always written during capture (the high-accuracy second-pass ASR and summary splice both read them), then deleted at the end of `endSession` when `StorageSettings.saveAudioFiles` is off.
- Voice profile storage: `~/Library/Application Support/SerialNotes/voices/` — JSON + WAV pairs. Don't bake any other personal data into this directory.
- Permissions reset when the `.app` path changes (different worktree = different path = TCC re-prompts). Expected.
- New meeting prompts should extend `MeetingBannerController`; don't add `UNUserNotificationCenter` flows unless you've thought through Focus/DND filtering and notification permission UX.
- Any feature that opens the mic outside a recording session must call `MeetingDetectionService.suspendDetection()` / `resumeDetection()` around its engine lifetime — otherwise it false-fires the banner.
- Any feature that programmatically stops a recording must route through `RecordingState.stop(reason:)` (or `stopAndWait(reason:)` if it needs to await finalization) with a `RecordingStopReason` that describes the trigger — not `stop()` with no arg. The reason flows into `session.json` and, for meeting-end stops, into the summary cutoff.
- Adding a new meeting app: add one row to `MeetingDetectionService.knownMeetingApps` with `displayName` + `coreAudioBundleSubstrings`. Both the start-detection path and the audio-activity monitor read from this table — do not introduce a parallel switch elsewhere.
- Transcript post-processing splits by scope: **per-utterance mutations** (punctuation, capitalization, anything that touches a single EOU's text) belong inside `TranscriptionService`'s EOU handlers — the 3-second flush delay (`flushOldEntries`) gives detached rewrite tasks headroom to complete before their entry's timestamp is flushed; do not add a separate per-entry post-write pass. **Whole-transcript passes** (summary, action items, anything that needs the full session) belong in `endSession()` after the file is finalized on disk, mirroring `spliceSummarySections` — read the file back, mutate, write atomically.
- The test target `@testable import SerialNotes`, so keep testable code at `internal` visibility; `private` types cannot carry `@Generable` or other macro-expanded conformances (moved out of `FoundationModelsRewriter` for this reason).

## Marketing site

The marketing/landing site lives in `site/` — a self-contained **Astro + Tailwind v4**
project that uses **bun**. It is **not** part of the macOS app build: SwiftPM only
compiles `Sources/` + `Tests/` via explicit `path:` targets, so `site/` is never swept
into the Swift build.

- **Dev:** `cd site && bun install && bun run dev` (serves on `localhost:4321`)
- **Build:** `cd site && bun run build` → `site/dist/`
- **Deploy:** Vercel, with the dashboard **Root Directory set to `site/`**.
  `site/vercel.json` pins the Astro framework and sets an `ignoreCommand` so commits
  that don't touch `site/` skip the build.
- Site-wide copy + links live in `site/src/consts.ts`.
