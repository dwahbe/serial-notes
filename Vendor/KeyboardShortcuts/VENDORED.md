# Vendored: sindresorhus/KeyboardShortcuts

- **Upstream:** https://github.com/sindresorhus/KeyboardShortcuts
- **Vendored from:** v3.0.1, revision `49c3fc04ea827f816df67843bfcc57286b47ff06`
- **License:** MIT (see `license`)
- **Omitted:** `.git`, `.github`, `.swiftpm`, `Example/`, logo/screenshot images

## Why this is vendored

The stock SwiftPM-generated `Bundle.module` accessor searches exactly two places:
the `.app` bundle **root** and the absolute `.build/...` path **of the machine that
compiled the binary**. Neither exists for a CI-built release on a user's Mac — code
signing requires resources to live under `Contents/Resources`, which the accessor
never checks — so touching any localized string fatalErrored in production
(v0.2.3/v0.2.4 crashed on opening Settings, where the shortcut recorder lives).
Dev machines mask the bug: the compiled-in `.build` fallback path exists locally.

## Local patch

One change, in `Sources/KeyboardShortcuts/Utilities.swift`:
`String.localized` resolves its bundle through `Bundle.keyboardShortcutsResources`
— a resilient lookup that prefers `Bundle.main.resourceURL` (where
`scripts/build-app.sh` copies the bundle) and falls back to `.module` for
SwiftPM-native contexts (`swift test`, local tooling). That was the package's only
`.module` use at this revision.

## Updating

Diff a fresh upstream checkout at the new tag against this directory, re-apply the
patch above (re-grep for new `Bundle.module` / `.module` uses — every one must go
through the resilient accessor), and update the revision line in this file.
