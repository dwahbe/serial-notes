# Serial Notes

A minimal macOS menu bar app that captures meeting audio, transcribes it locally, generates a summary + action items with Apple Intelligence, and exports clean Markdown to the notes app of your choice.

**No accounts. No cloud dependency. No lock-in.**

> [!NOTE]
> **Public beta.** Serial Notes is at `0.x` — free to download and use, with rough edges expected. It updates itself automatically as new builds ship (or check manually in **Settings → General → Check for Updates…**).

## Download

**[⬇ Download Serial Notes](https://github.com/dwahbe/serial-notes/releases/latest/download/SerialNotes.zip)** — a notarized build, so it opens with no Gatekeeper warnings. Unzip and drag **Serial Notes.app** into your Applications folder.

Requires **macOS 26+ (Tahoe)** on **Apple Silicon** — see [Requirements](#requirements).

## Principles

1. **Hidden.** Doesn't bother the user and doesn't show up in meeting apps.
2. **Safe.** Data never leaves your laptop unless you want it to.
3. **Simple.** Serial Notes produces a high-quality meeting transcript with an optional summary + action items. What you do with them afterwards is up to you.

## How It Works

1. **Detect** — Notices when a meeting app (Zoom, Meet, Teams, FaceTime, Slack, Webex, Discord) starts using the mic and offers a one-click record banner.
2. **Capture** — Records system audio via a CoreAudio process tap (no screen-recording prompt), with a ScreenCaptureKit fallback. Mic is captured in parallel via AVAudioEngine.
3. **Transcribe** — Runs locally on-device using [FluidAudio](https://github.com/FluidInference/FluidAudio): Parakeet streaming ASR for real-time text, LS-EEND for speaker diarization. Apple's on-device Foundation Models (when Apple Intelligence is on) restore punctuation + capitalization as each utterance lands.
4. **Summarize** — At session end, the same on-device Foundation Models generate a 3–6 bullet meeting summary and a list of action items with owners. Both sections are independently togglable; if Apple Intelligence isn't available the step is skipped silently.
5. **Export** — Writes a structured `transcript.md` (header → summary → action items → speaker entries) alongside the raw `system.wav` + `mic.wav` into a session folder in your chosen storage location (Obsidian vault, iCloud, any folder).

## Example Output

```markdown
---
date: 2026-04-24
duration: 47m
---

# Meeting — 2026-04-24 at 10:00 AM

## Summary

- Walked through onboarding flow concerns raised by the support team.
- Agreed to delay the activation prompt until day two and ship a fix this week.
- Reviewed Q3 launch checklist — marketing sync still outstanding.

## Action items

- [ ] **You** — Send the updated design doc by Friday
- [ ] **Person 1** — Schedule a follow-up with the platform team
- [ ] Update the launch checklist with the new activation timing

**You** (00:00:00): Alright, let's get started...
**Person 1** (00:00:15): I wanted to flag something on the onboarding flow...
**You** (00:00:42): Yeah, I saw that too — let's dig in.
```

Each session lives in its own folder:

```
~/Documents/SerialNotes/2026-04-24 at 10.00.00 AM/
├── transcript.md     # what you share
├── system.wav        # raw meeting-side audio
└── mic.wav           # raw mic audio
```

Don't need the raw audio? Turn **Save Audio Files** off in Settings → General (or the menu bar popover) and the WAVs are removed once the transcript is finalized — `transcript.md` is all that's left.

## Requirements

- macOS 26+ (Tahoe)
- Apple Silicon (M1+) — required for CoreML model performance
- Xcode 26+ (Swift tools 6.2)
- Microphone + System Audio Recording permissions
- ~1 GB free disk space for transcription models (downloaded from Hugging Face on first launch)
- Apple Intelligence (optional) — enables punctuation restoration, meeting summaries, and action items. The app works without it; those steps are skipped.

## Running locally

```bash
./scripts/run.sh          # build + wrap as .app + launch
./scripts/build-app.sh    # build + wrap only
swift test                # run tests
```

The app is built via SwiftPM and wrapped into a proper `.app` bundle by the build script. LaunchServices-gated APIs (menu bar extras, URL schemes, notification center) require the binary to live inside a signed `.app`, so **don't use `swift run`** — it produces a raw binary that can't register with LaunchServices and crashes on first TCC-gated call.

On first launch, models are prefetched in the background from Hugging Face (~1 GB) so the record button is ready when a meeting starts.

## Tech Stack

- **Language:** Swift 6 / SwiftUI (`@Observable`, `@MainActor`, actor-isolated services)
- **Audio Capture:** CoreAudio process tap (primary) → ScreenCaptureKit fallback; AVAudioEngine for mic
- **Transcription:** [FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet EOU streaming ASR (160ms chunks, on-device CoreML)
- **Diarization:** FluidAudio LS-EEND (DIHARD III) on both mic and system streams
- **LLM post-processing:** Apple Foundation Models (on-device, macOS 26+) via `@Generable` schemas — per-utterance punctuation/capitalization + end-of-session summary and action items
- **Updates:** [Sparkle](https://sparkle-project.org) — Developer ID-signed, notarized auto-updates driven by an EdDSA-signed appcast
- **No Electron. No web views.** The only network calls are the one-time model download and periodic Sparkle update checks.

## Non-Goals

- **Not a notes app.** Exports and gets out of the way.
- **Not cross-platform.** macOS only by design.

## Privacy

- All transcription, punctuation restoration, summarization, and action-item extraction run locally on-device
- No analytics, no telemetry
- FluidAudio models are downloaded once from Hugging Face; Apple's Foundation Models base model is managed by the OS
- Auto-update checks fetch a small appcast from GitHub — no system profiling or identifiers are sent. Aside from that and the one-time model download, your audio and transcripts never leave your machine
- Audio is retained indefinitely on-device (delete session folders to clean up)

## Marketing site

The marketing site lives in [`site/`](site/) — a self-contained Astro + Tailwind v4
project (bun). It deploys to Vercel with the **Root Directory set to `site/`** and is
**not** part of the macOS app build.

```bash
cd site
bun install
bun run dev      # localhost:4321
bun run build    # → site/dist/
```

## License

MIT
