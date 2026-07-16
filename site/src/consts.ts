// Single source of truth for site-wide content + links.
export const SITE = {
  name: "Serial Notes",
  title: "Serial Notes — Free, private meeting transcription for Mac",
  description:
    "A menu bar app for macOS that captures your meetings, transcribes them on-device, and exports clean Markdown — sent straight to Notion and Apple Notes, ready for Obsidian.",
  url: "https://serialnotes.app",

  // Links
  github: "https://github.com/dwahbe/serial-notes",
  download: "https://github.com/dwahbe/serial-notes/releases/latest/download/SerialNotes.dmg",
  email: "hello@serialnotes.app",

  // Authors
  authors: [
    { name: "Dylan Wahbe", url: "https://dylanwahbe.com" },
    { name: "Ian Wahbe", url: "https://iwahbe.com" },
  ],
} as const;
