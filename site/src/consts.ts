// Single source of truth for site-wide content + links.
export const SITE = {
  name: "Serial Notes",
  title: "Serial Notes — Meeting notes, where you already work",
  description:
    "A menu bar app for macOS that captures your meetings, transcribes them on-device, and exports clean Markdown — ready for Notion, Apple Notes, and Obsidian.",
  url: "https://serialnotes.app",

  // Links
  github: "https://github.com/dwahbe/serial-notes",
  download: "https://github.com/dwahbe/serial-notes/releases/latest/download/SerialNotes.dmg",

  // Authors
  authors: [
    { name: "Dylan Wahbe", url: "https://dylanwahbe.com" },
    { name: "Ian Wahbe", url: "https://iwahbe.com" },
  ],
} as const;
