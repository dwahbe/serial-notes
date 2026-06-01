# Design

## Fundamentals

- Menu bar-only app — no Dock icon, no main window
- macOS 26+, Liquid Glass throughout
- Single `MenuBarExtra` popover (`.window` style), dark color scheme
- Two states: **idle** (controls + storage picker) and **recording** (timer + stop)

## Layout

- Popover width: 280pt
- Content padding: 20pt
- Vertical spacing: 16pt between sections
- State transitions (idle↔recording) resize the popover instantly — do **not**
  animate the root size. `MenuBarExtra(.window)` won't resize its NSWindow off an
  animated size change, which leaves a transparent dead zone + detached shadow
  when the shorter recording layout is shown. See `MenuBarView.body`.

## Liquid Glass Rules

- Wrap the entire popover in `GlassEffectContainer`
- `.glassProminent` for the single primary action per state
- `.glass` for secondary interactive elements
- Never apply glass to content (text, labels, status indicators)
- Never stack glass without a `GlassEffectContainer`
- Never mix `.regular` and `.clear` glass variants
- No custom tints — system defaults only

## Icons

- Monochrome SF Symbols only
- Menu bar icon reflects state: `waveform.circle` (idle), `record.circle` (recording)

## Typography & Hierarchy

- System fonts; `.monospaced` design for time/numeric displays
- `.numericText()` content transition for changing numbers
- `.primary` for interactive elements and key info
- `.secondary` for labels and supporting icons
- `.tertiary` for disclosure indicators and hints
- Errors: `.red` foreground, `.caption` font, 2-line max

## System Panels

- Use `NSOpenPanel` / `NSSavePanel` for file operations
- Set `.regular` activation policy before presenting, restore `.accessory` after
