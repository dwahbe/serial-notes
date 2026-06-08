# CLAUDE.md

## What is this?

Serial Notes — a menu bar-only macOS app that captures meeting audio, transcribes locally, and exports Markdown. See `README.md` for full product context.

## Project status

Public, open-source (MIT — see `LICENSE`). Repo: github.com/dwahbe/serial-notes.
Implications: commit history, messages, code comments, issues, and PRs are all
world-readable and permanent — write them as publishable. No security-through-
obscurity: secrets never go in the repo (CI secrets live in GitHub Secrets).

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

**Dev vs production identity:** ad-hoc local builds (`run.sh`, or `build-app.sh`
with no `SIGN_IDENTITY`) get a distinct `com.serialnotes.app.dev` bundle ID +
"Serial Notes (Dev)" name, and the app tags itself **"DEV"** in the menu bar
(`Bundle.isDevBuild`, derived from the `.dev` suffix). This lets a local build run
side-by-side with a downloaded production build without sharing its TCC
permissions or UserDefaults domain. Release/CI builds sign with a real Developer
ID, so they skip the `.dev` flavor (gated on `SIGN_IDENTITY == "-"` in
`build-app.sh`) and ship as plain `com.serialnotes.app` — the "DEV" marker can
never reach a notarized download. On-disk data (voice profiles, the default
storage dir) is **not** isolated by the dev flavor, since those are fixed paths.

To keep the side-by-side promise, `run.sh`'s pre-build process cleanup is **scoped
to this repo's own dev build only** — it kills processes whose full path is
`$ROOT/.build/SerialNotes.app/Contents/MacOS/SerialNotes` (via `pkill -f` on the
absolute path), never the bare executable name or the bundle-relative
`Contents/MacOS/SerialNotes` suffix. Dev and a downloaded production build ship the
*same* executable name and the same internal suffix, differing only by location +
bundle ID, so `killall SerialNotes` or a suffix match would terminate the user's
production app too. The `debugserver`/`lldb`/`DerivedData` kills stay broad (dev-only
artifacts). When asked to "stop the local instance" / "kill the local app," that
always means this dev build, never a production install.

## Releases

```bash
./scripts/release.sh 0.2.0           # validate + tag + push (CI builds & publishes)
```

Releases run in **GitHub Actions** (`.github/workflows/release.yml`), triggered by
pushing a `vX.Y.Z` tag. `release.sh` is just the trigger — it validates a clean
tree, tags, and pushes; CI does build → Developer ID sign → notarize → staple →
GitHub Release → Sparkle update sign → appcast commit. Build/notarize **locally**
only for testing (`SIGN_IDENTITY=… build-app.sh release` + `notarytool submit`) —
don't publish locally, since a pushed tag already triggers the CI release.

- **Versioning:** SemVer. While in beta we stay on `0.x.y` — major version `0` is
  the "beta" signal: the Settings → About row derives "(beta)" from it, and CI
  titles the GitHub release `vX.Y.Z (beta)`. Beta builds ship as **full GitHub
  releases, not pre-releases**, so `/releases/latest` and the site download link
  resolve. Bump to `1.0.0` to drop "(beta)". No `-beta` strings to maintain.
- **Single source of truth = the git tag.** `build-app.sh` stamps
  `CFBundleShortVersionString` from the tag (`vX.Y.Z` → `X.Y.Z`) and
  `CFBundleVersion` from the commit count, via `PlistBuddy`, before signing. CI
  passes `MARKETING_VERSION` so the artifact matches the tag. The keys in
  `Info.plist` are only fallbacks for builds made outside a git checkout.
- **Distribution asset** is a stable-named `SerialNotes.zip` uploaded per release,
  so the site links to `…/releases/latest/download/SerialNotes.zip`; each release's
  per-tag URL stays unique for Sparkle's appcast.
- **Signing:** Developer ID Application + hardened runtime + secure timestamp,
  notarized + stapled. `build-app.sh` embeds + inside-out signs `Sparkle.framework`
  (helpers first, then the framework, then the app). Locally it auto-detects the
  Developer ID cert; in CI it's imported from secrets. **Ad-hoc dev builds skip
  hardened runtime** (`build-app.sh` adds `--options runtime` only for a real
  identity) — otherwise library validation kills the ad-hoc app at launch for
  loading the team-less ad-hoc `Sparkle.framework`; release builds are safe because
  app + framework share one Developer ID team. (A notarized, stapled `.app` opens
  with no quarantine `xattr` dance.)
- **Auto-updates (Sparkle):** each release archive is EdDSA-signed (`sign_update`)
  and a new item is prepended to `appcast.xml` (`scripts/update_appcast.py`), which
  CI commits to `main`. `SUFeedURL` (in `Info.plist`) points at the raw
  `appcast.xml`; `SUPublicEDKey` is the EdDSA public key. The private key lives in
  the keychain (and a GitHub secret for CI; export with `generate_keys -x`).
- **Release notes** are GitHub-native: `--generate-notes` groups merged PRs by
  label per `.github/release.yml`. No separate `CHANGELOG.md` — the Releases page
  is the canonical changelog.
- **CI secrets** (Settings → Secrets and variables → Actions): `BUILD_CERTIFICATE_BASE64`,
  `P12_PASSWORD`, `KEYCHAIN_PASSWORD`, `NOTARY_API_KEY_BASE64`, `NOTARY_KEY_ID`,
  `NOTARY_ISSUER_ID`, `SPARKLE_ED_PRIVATE_KEY_BASE64`.

## Project Structure

```
Package.swift              # SwiftPM manifest (executable + tests + ObjC module)
scripts/
  build-app.sh             # swift build → wrap .app → embed+sign Sparkle → stamp version → codesign → lsregister
  run.sh                   # kill existing instance → build-app.sh → open .app
  release.sh               # validate clean tree → git tag → push (triggers CI release)
  update_appcast.py        # prepend a signed item to appcast.xml (run by CI)
icon/
  AppIcon.svg              # 1024px app-icon master (brand mark — see DESIGN.md)
  make-icon.sh             # regenerate AppIcon.icns (qlmanage → sips → iconutil)
.github/workflows/
  release.yml              # tag-triggered: build → notarize → staple → GitHub Release → appcast
appcast.xml                # Sparkle update feed (served raw from main; CI commits new items)
Sources/
  SerialNotes/             # Main app target (SwiftUI executable)
    SerialNotesApp.swift              # Entry point: MenuBarExtra + Settings + onboarding
                                      #   Window scenes; owns the Sparkle UpdaterController;
                                      #   kicks off model download + auto-opens the first-run
                                      #   guide at launch; wires detector → recording stop
                                      #   callbacks; drains finalization on app quit
    MenuBarView.swift                 # Popover UI (idle + recording states)
    SettingsView.swift                # Settings window — General / People / Meetings tabs
    SettingsNavigation.swift          # @Observable nav coordinator: selectedTab,
                                      #   openSettingsAction / openSetupAction (lets
                                      #   non-view code front Settings + the setup window),
                                      #   pendingNamingSession deep-link
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
    MeetingDetectionService.swift     # Wires start detection (edge-triggered input-
                                      #   capture monitor → MeetingStartDetector → banner)
                                      #   + owns call-end monitoring + state machine
    MeetingInputCaptureMonitor.swift  # Start-detection input watcher: tracks every known
                                      #   meeting app's per-process IsRunningInput (process-
                                      #   list + per-process listeners + ~1.5s poll safety
                                      #   net), emits the set of bundle IDs capturing the mic
    MeetingAudioActivityMonitor.swift # Per-process CoreAudio listener
                                      #   (kAudioProcessPropertyIsRunningInput/Output)
                                      #   for detecting when the associated meeting
                                      #   app stops producing audio (call-end)
    MeetingAudioProcessReader.swift   # Shared CoreAudio per-process reads (process
                                      #   object list + bundle/PID/input/output flags).
                                      #   Single source used by both the call-end
                                      #   monitor and the start-detection input monitor
    MeetingAudioTypes.swift           # Boundary value types: MeetingRecordingAssociation,
                                      #   MeetingAudioProcessSnapshot,
                                      #   MeetingAudioActivitySnapshot,
                                      #   MeetingAudioActivityState,
                                      #   MeetingSessionDiagnostics
    MeetingStartDetector.swift        # Pure-reducer for start detection: baselines the
                                      #   first scan, prompts only on a fresh capture
                                      #   transition sustained past a debounce, with
                                      #   per-episode dismiss suppression + a lock
    CallEndStateMachine.swift         # Pure-reducer state machine for the call-end
                                      #   timeline (monitoring → inactiveGrace →
                                      #   prompting → suppressed) emitting [Effect]
                                      #   cases consumed by MeetingDetectionService
    RecordingStopReason.swift         # Stop-reason enum (.manual / .callEndedAuto /
                                      #   .appQuit) + MeetingCallEndContext
                                      #   (carries inactiveAt used as summary cutoff)
    MeetingBannerWindow.swift         # Floating NSPanel banner (start prompt +
                                      #   call-ended prompt modes)
    VoiceProfile.swift                # Profile data type (.you / .other)
    VoiceProfileStore.swift           # On-disk profile store (JSON + WAV pairs)
    VoiceEnrollmentRecorder.swift     # @Observable mic recorder used by enrollment
    VoiceEnrollmentFlowView.swift     # Face-ID-style guided enrollment flow
    MeetingSessionsStore.swift        # @Observable store of recent sessions with
                                      #   unnamed speakers (drives the Meetings tab)
    SpeakerClipExtractor.swift        # Pulls per-speaker audio clips from a session
                                      #   for post-meeting naming / enrollment
    SpeakerNamingView.swift           # Sheet to name a session's detected speakers
    SystemAudioPermission.swift       # Fires the system-audio TCC prompt by creating +
                                      #   tearing down a tap (no read-only status API exists)
    OnboardingSettings.swift          # First-run state (hasShown / completed) in UserDefaults
    OnboardingFlowView.swift          # Face-ID-style first-run setup guide (permissions →
                                      #   Apple Intelligence → storage → voice)
    SetupFlowChrome.swift             # Shared chrome for the setup flows (SetupStepIcon,
                                      #   BulletList, PhraseDots, WindowCloseChrome)
    UpdaterController.swift           # Sparkle updater wrapper (@Observable): starts the
                                      #   updater, drives "Check for Updates…", + a gentle-
                                      #   reminder delegate so the menu-bar app fronts alerts
    BuildFlavor.swift                 # Bundle.isDevBuild — true for the .dev ad-hoc build,
                                      #   so the menu bar tags it "DEV" (see Build & Run)
    AppIcon.icns                      # App icon copied into .app/Contents/Resources
                                      #   by build-app.sh (regenerate: ./icon/make-icon.sh)
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
    MeetingStartDetectorTests.swift       # Edge-triggered start reducer: baseline /
                                          #   transition / debounce / dismiss / lock
    MeetingAudioActivityMonitorTests.swift # CoreAudio process-list monitor smoke tests
    MeetingInputCaptureMonitorTests.swift # Start-detection input monitor smoke test
    MeetingAttributionTests.swift         # Pure mic-ownership mapping +
                                          #   related-bundle-ID grouping tests
    MeetingSettingsTests.swift            # Auto-stop toggle persistence
    MeetingSessionsStoreTests.swift       # Sessions store: list / name / skip / relabel
    SpeakerClipExtractorTests.swift       # Per-speaker clip extraction
    SpeakerRelabelTests.swift             # Transcript speaker-relabel pass
    OnboardingSettingsTests.swift         # First-run hasShown / completed persistence
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
- **Summary cutoff for auto-stopped recordings**: when a recording stops via `.callEndedAuto`, the `MeetingCallEndContext.inactiveAt` timestamp is threaded through `TranscriptionService.endSession(summaryCutoff:)` into `TranscriptFormatter.summaryInput(from:cutoff:)`. Entries with a timestamp at or beyond the cutoff are excluded from the summary input only — they remain in the on-disk transcript. This keeps post-call hallway audio out of the summary without losing it. Manual stops pass `nil` (no cutoff).
- **Voice enrollment**: `VoiceProfileStore` persists profiles to `~/Library/Application Support/SerialNotes/voices/` as `<uuid>.json` + `<uuid>.wav` pairs. `VoiceEnrollmentRecorder` captures a short mic clip with per-phrase silence detection (RMS threshold + hangover) and advances through three phrases. `VoiceEnrollmentFlowView` is the Face-ID-style guided UI. Decoded WAV samples are cached in `VoiceProfileStore` after first read (invalidated by `reload()`, which runs after every save / rename / delete). On session start, `RecordingState` hands enrollment clips, a `SummarySettings.Snapshot`, and the preferred name to `TranscriptionService.startSession(enrollments:summarySettings:micPrimaryName:)`, which primes each diarizer so matching voices get named instead of labeled `You` / `Person N`, and constructs + prewarms the summarizer if needed.
- **Preferred name**: `IdentitySettings.yourName` (UserDefaults, set in Settings → People) is the user's *optional* display name — independent of voice enrollment, so it works even with no recorded sample. `IdentitySettings.micDisplayName` (the trimmed name, or `You` when unset) is threaded through `RecordingState.start()` into `startSession(micPrimaryName:)` and becomes the single label for the user's mic voice in three places that must agree: the streaming default mic label (`labelForSpeaker`), the `.you` diarizer enrollment label (set in `loadEnrollments` so matched segments carry the same name), and the final-render `CrossChannelEchoFilter.normalizeMicLabels` collapse target. The whole mic side therefore reads as the preferred name instead of `You`. The enrollment flow's naming step pre-fills from / writes back to the same setting.
- **Detection suspend/resume**: any code that holds the mic for non-meeting purposes (currently just `VoiceEnrollmentRecorder`) must call `MeetingDetectionService.suspendDetection()` before engine start and `resumeDetection()` on stop. Otherwise enrollment audio would false-fire the "meeting detected" banner. Wiring lives in `SettingsView`'s `PeopleSettingsTab.onAppear`.
- **Settings scene**: a standard SwiftUI `Settings { … }` scene (not a bespoke window) with three tabs — **General / People / Meetings**. `WindowCloseChrome` (in `SetupFlowChrome.swift`, shared with the onboarding + enrollment windows) observes the hosting NSWindow's `willCloseNotification` and restores `NSApp.setActivationPolicy(.accessory)` **only when no other titled window remains** — so Settings and the setup guide can be open together without fighting over activation policy. Without it, clicking the gear flips the app to `.regular` and leaves it visible in Dock + Cmd-Tab after the window closes.
- **Auto-updates (Sparkle)**: `UpdaterController` (`@Observable`, owned by `SerialNotesApp`) wraps `SPUStandardUpdaterController(startingUpdater: true)`, mirrors its KVO `canCheckForUpdates` for the Settings → General → "Check for Updates…" button, and installs an `SPUStandardUserDriverDelegate` that declares `supportsGentleScheduledUpdateReminders` and calls `NSApp.activate()` when an update alert is about to show — without it, a scheduled update prompt appears *behind* other apps because this is an `.accessory`/LSUIElement app. Feed + key config (`SUFeedURL`, `SUPublicEDKey`) live in `Info.plist`; the signing/appcast pipeline is in the Releases section.
- **First-run setup guide**: `OnboardingFlowView` (a `Window` scene, id `onboardingWindowID`) walks a fresh install through mic + system-audio permissions → Apple Intelligence → storage location → optional voice enrollment. `OnboardingSettings` persists `hasShown` / `completed` in UserDefaults (survives Sparkle's in-place `.app` replacement, so it never re-triggers on update). The guide marks itself shown in its **own `.onAppear`** (not at the decide-to-open point) so a failed `openWindow` retries next launch instead of suppressing onboarding forever, and it suspends meeting detection for its whole lifetime. `SystemAudioPermission.requestSystemAudioPermission()` fires the system-audio TCC prompt by creating + tearing down a tap (there is no read-only status API), so the guide re-probes on `didBecomeActive`.
- **Meeting detection — edge-triggered**: `MeetingDetectionService` drives the start prompt off **input-capture transitions**, not the level of "is the mic in use". `MeetingInputCaptureMonitor` watches every known meeting app's per-process `kAudioProcessPropertyIsRunningInput` (process-list listener + per-process listeners + a ~1.5s poll safety net for apps whose CoreAudio notifications drop, notably Zoom) and emits the set of bundle IDs currently capturing the mic. That stream feeds the pure `MeetingStartDetector` reducer, which prompts **only when a known meeting app freshly *starts* capturing** (a false→true transition) and sustains it past a debounce. This is what fixes the idle-Zoom false positive: an app that merely *warm-holds* the mic with no call produces no transition, so it never prompts. Known meeting apps are encoded in `knownMeetingApps: [String: KnownMeetingApp]` — each entry pairs the visible bundle ID with a `displayName` and a list of `coreAudioBundleSubstrings` used by the shared `knownMeetingAppBundleID(for:)` matcher. Single source of truth — adding a new meeting app means adding one row. Currently: Zoom, Microsoft Teams (v1 + v2), FaceTime, Slack, Webex, Discord. The monitor only runs while **at least one known meeting app is running** (`runningMeetingApps`, maintained by NSWorkspace launch/terminate) and no recording session is in flight — so when no meeting app is open there's zero polling at idle (`shouldMonitorInput` is the single gate, applied via `updateInputMonitoring`). NSWorkspace activate notifications maintain an `activationOrder` for disambiguating simultaneous transitions (frontmost → most-recently-activated → alphabetical, never `Set.first`). A transient `readProcessObjectList()` failure is **not** reported as "nothing capturing" — the monitor preserves the last-known set (mirroring the call-end monitor's `.unknown`) so an ongoing call isn't seen as ended and re-prompted on recovery.
- **`MeetingStartDetector` semantics — baseline + transition + debounce + lock**: the first capturing-set snapshot is the **baseline** — anything already capturing when the monitor starts is treated as in-progress and never prompts (so launching mid-call gives no auto-prompt; recording manually still works). After baseline, a known app entering the capturing set is a candidate; it prompts only after `debounceSeconds` of sustained capture (the service runs the timer and calls `debounceTimerFired`), which rejects momentary idle mic-pokes. One prompt at a time: the reducer **locks** to the prompted app and ignores others until it stops capturing. When the prompted/pending app stops, the lock/episode clears, so the same app re-prompts only on a genuinely new call (stop → start). On machines where the per-process API is unavailable, no apps ever surface as capturing → no prompts (there is no focus-order fallback — that was the false-positive source).
- **Dismiss / Stop-while-in-call**: `dismiss()` marks the current capture episode **suppressed** so the dismissed app stays quiet until it stops capturing — but a *different* app that starts capturing later in the same window still prompts (a real new call). The banner's 15s auto-dismiss routes through the same dismiss action (not a bare `hide()`), so ignoring the prompt clears the reducer lock + `detectedMeeting` rather than wedging a stale "detected" offer in the popover for the rest of the call. A recording session in any phase (starting / active / finalizing, via `RecordingState.isRecordingSessionActive`) pauses the start monitor entirely and re-baselines on resume — `RecordingState` fires `onRecordingChange` *after* `finalizationTask` is set and again after it clears, so the monitor stays paused through finalization and there's no window where a swallowed prompt leaves a phantom lock.
- **Auto-end recording**: when a recording starts and is associated with a detected meeting app (`MeetingStartDetector.lockedBundleID` — the app the start prompt locked onto, so a manual recording with no detected meeting gets no auto-stop and can't be falsely stopped by an idle app releasing the mic), `MeetingDetectionService` spins up `MeetingAudioActivityMonitor` against that app. The monitor installs a `kAudioHardwarePropertyProcessObjectList` listener and per-process `kAudioProcessPropertyIsRunningInput/Output` listeners on every matched process (matched by exact bundle ID + the `coreAudioBundleSubstrings` loose fallback). The monitor is **not purely event-driven**: CoreAudio per-process `IsRunningInput/Output` change notifications fire unreliably for some meeting apps (notably Zoom), so a 3s polling fallback (`MeetingAudioActivityMonitor.startPolling`) re-reads process state on a timer and re-notifies — without it a dropped "became active" / "became inactive" callback would wedge the machine in `monitoring` forever. Activity changes feed `CallEndStateMachine`, a pure reducer with phases `monitoring → inactiveGrace → prompting → suppressed` and effects routed back through `handleCallEndEffects`. Defaults: **2s inactive grace** (short debounce against mid-call audio blips; prompt appears almost as soon as the call ends), **5s countdown**. Both durations live only on the reducer (`inactiveGraceSeconds` / `countdownSeconds`) — `scheduleCallEndGraceTimer` and `startCallEndCountdown` read them rather than hardcoding, so the timers and the reducer can't drift. The end-call banner is a calm "wrapping up recording" notice with a single **Keep Recording** button — no visible countdown and no "Stop Now" (the recording still auto-stops when the window elapses; the countdown runs as one internal sleep, not a per-second tick). Auto-stop fires `.callEndedAuto`, carrying a `MeetingCallEndContext` whose `inactiveAt` drives the summary cutoff. "Keep Recording" puts the machine in `.suppressed` and tears the monitor down — no second prompt fires for that recording. The auto-stop suppression is **per-recording** and lives in the state machine; it is intentionally distinct from the start-prompt machinery's per-episode suppression in `MeetingStartDetector`. Manual recordings (no detected association) and recordings on machines where the per-process CoreAudio API is unavailable skip auto-stop entirely. The toggle is `MeetingSettings.autoStopAfterCallEnds` (on by default; user-toggleable in Settings via the "Stop recording after call ends" row).
- **Stop reasons**: `RecordingState.stop(reason: RecordingStopReason = .manual)` accepts `.manual`, `.callEndedAuto(MeetingCallEndContext)`, and `.appQuit`. The reason is written to `session.json`. `stop(reason:)` is fire-and-forget; the synchronous variant `stopAndWait(reason:)` (used by `applicationShouldTerminate`) awaits a shared `finalizationTask` so app-quit drains transcript finalization + summary splice before the process exits. The `MeetingCallEndContext.inactiveAt` is the only cutoff signal used by the summary input — keep all summary-cutoff logic flowing through `RecordingStopReason.summaryCutoffDate` rather than reaching into state machine internals.
- **Prompt surface**: `MeetingBannerController` renders a custom borderless `NSPanel` (Granola-style) in the top-right of the active screen. `.statusBar` level + `canJoinAllSpaces + fullScreenAuxiliary` collection so it floats over fullscreen Zoom and follows spaces. Two modes: the **start prompt** ("Meeting detected", auto-dismisses after 15s) and the **end-call prompt** ("…call ended — wrapping up recording", single Keep Recording button; dismisses only on activity resume, Keep Recording, recording stop, or auto-stop — never on a timer).
- **Networking is minimal.** Everything runs locally. Exceptions: FluidAudio model downloads from Hugging Face on first launch; Apple's on-device Foundation Models (which may pull its base model through system channels outside the app's control); and Sparkle auto-update checks (fetch the GitHub-hosted `appcast.xml` and download update archives — no system profiling is sent).

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
