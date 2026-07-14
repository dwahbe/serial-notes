# Serial Notes

Serial Notes is a macOS menu bar app that records your meetings and turns them into clean Markdown: a transcript with speaker labels, a short summary, action items, and any notes you jotted during the call. Everything runs on your Mac, and the result lands in whatever notes app you already use.

**No accounts. No cloud. No lock-in.**

> [!NOTE]
> **Public beta.** Serial Notes is at `0.x` — it's free, and there will be rough edges. The app keeps itself up to date as new builds ship, or check manually in **Settings → General → Check for Updates…**

## Download

**[⬇ Download Serial Notes](https://github.com/dwahbe/serial-notes/releases/latest/download/SerialNotes.dmg)**

Requires **macOS 26+ (Tahoe)** on **Apple Silicon** — see [Requirements](#requirements).

## Principles

1. **Hidden.** No bot joins your call and nothing shows up on screen. It lives in the menu bar and stays out of your way.
2. **Safe.** Data never leaves your laptop.
3. **Simple.** You get a good transcript, plus a summary and action items if you want them. What you do with them afterwards is up to you.

## How it works

When a meeting app starts using your mic — Zoom, Teams, FaceTime, Slack, Webex, or Discord — a small banner offers to record. (Browser calls like Google Meet don't auto-detect; just start recording from the menu bar.) One click and Serial Notes captures both sides of the call: system audio through a CoreAudio process tap (no screen-recording prompt; ScreenCaptureKit as a fallback), and your mic through AVAudioEngine.

Transcription happens live on your Mac with [FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet for streaming speech-to-text, LS-EEND to tell speakers apart. If Apple Intelligence is on, Apple's on-device Foundation Models restore punctuation and capitalization as each line arrives. There's also a small Markdown notepad you can open during the call; whatever you write is autosaved and included in the final document, though it never feeds the generated summary.

When the meeting ends, the same on-device models write a 3–6 bullet summary and pull out action items with owners. Both are optional, and both are skipped quietly if Apple Intelligence isn't available. The result is a structured `transcript.md` — your notes, then the summary and action items, then the full conversation — saved next to the raw audio in whatever folder you choose: an Obsidian vault, iCloud, anywhere.

## Example output

```markdown
---
date: 2026-04-24
duration: 47m
---

# Meeting — 2026-04-24 at 10:00 AM

## Notes

- Ask Morgan whether the beta invite list is final.
- Customer wants a migration checklist before launch.

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
- Apple Silicon (M1 or newer) — the CoreML models depend on it
- Microphone + System Audio Recording permissions
- ~1 GB of free disk space for the transcription models (fetched from Hugging Face on first launch)
- Apple Intelligence (optional) — powers punctuation restoration, summaries, and action items; everything else works without it

## Building from source

```bash
./scripts/run.sh          # build + wrap as .app + launch
./scripts/build-app.sh    # build + wrap only
swift test                # run tests
```

You'll need Xcode 26+ (Swift tools 6.2). The app is compiled with SwiftPM and wrapped into a proper `.app` bundle by the build script — don't use `swift run`. Menu bar extras, URL schemes, and notifications only work from inside a signed `.app`, so a raw binary can't register with LaunchServices and crashes on its first permission-gated call.

On first launch, the app prefetches the models from Hugging Face in the background so the record button is ready when a meeting starts.

## Tech stack

- **Language:** Swift 6 / SwiftUI (`@Observable`, `@MainActor`, actor-isolated services)
- **Audio capture:** CoreAudio process tap, falling back to ScreenCaptureKit; AVAudioEngine for the mic
- **Transcription:** [FluidAudio](https://github.com/FluidInference/FluidAudio) Parakeet EOU streaming ASR (160ms chunks, on-device CoreML)
- **Diarization:** FluidAudio LS-EEND (DIHARD III) on both the mic and system streams
- **LLM post-processing:** Apple Foundation Models (on-device, macOS 26+) — per-utterance punctuation and capitalization, plus the end-of-session summary and action items
- **Updates:** [Sparkle](https://sparkle-project.org) — Developer ID-signed, notarized auto-updates from an EdDSA-signed appcast

No Electron, no web views. The only network calls are the one-time model download and Sparkle's periodic update check.

## Non-goals

- **Not a notes app.** The built-in notepad is only for jotting during a meeting; the exported Markdown is the source of truth.
- **Not a meetings app.** Use whichever meeting app you like.

## Privacy

- Transcription, punctuation, summaries, and action items all run on-device
- No analytics, no telemetry
- The FluidAudio models are downloaded once from Hugging Face; Apple's Foundation Models base model is managed by the OS
- Update checks fetch a small appcast file — no identifiers or system profiling attached. Beyond that and the one-time model download, your audio and transcripts never leave your machine
- Recordings stay on your Mac until you delete their session folders

## Marketing site

The marketing site lives in [`site/`](site/): a self-contained Astro + Tailwind v4 project built with bun. It deploys to Vercel (Root Directory set to `site/`) and isn't part of the macOS app build.

```bash
cd site
bun install
bun run dev      # localhost:4321
bun run build    # → site/dist/
```

## License

MIT
