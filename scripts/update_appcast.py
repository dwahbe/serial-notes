#!/usr/bin/env python3
"""Insert (or replace) a signed update item in the Sparkle appcast.

Run by the release workflow after an update archive is signed with
`sign_update`. Items are keyed by short version string, so re-running a release
for the same version replaces its item rather than duplicating it. Sparkle
picks the highest `sparkle:version` (the CFBundleVersion / build number)
regardless of order, but items are inserted newest-first by convention.

Usage:
  update_appcast.py --appcast appcast.xml --title "Version 0.2.0" \
    --version 65 --short-version 0.2.0 --min-system 26.0 \
    --url https://.../SerialNotes.dmg \
    --signature 'sparkle:edSignature="..." length="12345"' \
    --release-notes-link https://.../releases/tag/v0.2.0 \
    --release-notes-file /tmp/release-notes.html

--signature is the raw stdout of `sign_update` (edSignature + length attrs).
--release-notes-file is embedded as the item's <description> (Sparkle's What's
New pane); --release-notes-link only sets the item's <link> permalink.
"""
import argparse
import re
import sys
import xml.etree.ElementTree as ET
from email.utils import formatdate

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", DC)

SKELETON = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    f'<rss version="2.0" xmlns:sparkle="{SPARKLE}" xmlns:dc="{DC}">\n'
    "  <channel>\n"
    "    <title>Serial Notes</title>\n"
    "    <description>Most recent updates to Serial Notes.</description>\n"
    "    <language>en</language>\n"
    "  </channel>\n"
    "</rss>\n"
)


def parse_signature(raw: str):
    ed = re.search(r'edSignature="([^"]+)"', raw)
    length = re.search(r'length="([^"]+)"', raw)
    if not ed or not length:
        sys.exit(f"could not parse sign_update output: {raw!r}")
    return ed.group(1), length.group(1)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--appcast", required=True)
    p.add_argument("--title", required=True)
    p.add_argument("--version", required=True, help="CFBundleVersion / build number")
    p.add_argument("--short-version", required=True, help="marketing version, e.g. 0.2.0")
    p.add_argument("--min-system", required=True, help="minimum macOS, e.g. 26.0")
    p.add_argument("--url", required=True, help="enclosure download URL")
    p.add_argument("--signature", required=True, help="raw sign_update stdout")
    p.add_argument("--release-notes-link", default=None, help="permalink for <link>")
    p.add_argument(
        "--release-notes-file",
        default=None,
        help="path to an HTML file embedded as the item's <description> (Sparkle's "
        "What's New pane). Preferred over a releaseNotesLink so the dialog doesn't "
        "load the GitHub release page and its repo nav chrome.",
    )
    args = p.parse_args()

    ed_sig, length = parse_signature(args.signature)

    try:
        tree = ET.parse(args.appcast)
        root = tree.getroot()
    except (FileNotFoundError, ET.ParseError):
        root = ET.fromstring(SKELETON)
        tree = ET.ElementTree(root)

    channel = root.find("channel")
    if channel is None:
        sys.exit("appcast has no <channel> element")

    # Idempotent re-runs: drop any existing item for this short version.
    for item in channel.findall("item"):
        sv = item.find(f"{{{SPARKLE}}}shortVersionString")
        if sv is not None and sv.text == args.short_version:
            channel.remove(item)

    notes_html = ""
    if args.release_notes_file:
        with open(args.release_notes_file, encoding="utf-8") as fh:
            notes_html = fh.read().strip()

    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.title
    if args.release_notes_link:
        # <link> is just the item's permalink (the GitHub release page).
        ET.SubElement(item, "link").text = args.release_notes_link
    if notes_html:
        # Preferred path: embed the release notes as self-contained HTML so the
        # "What's New" pane shows the changes inline. ElementTree escapes it on
        # write; Sparkle's XML parser un-escapes it back into HTML for the WebView,
        # so no CDATA wrapper is needed. (We deliberately do NOT emit a
        # sparkle:releaseNotesLink here — that would make Sparkle load the GitHub
        # release page, dragging the whole repo nav into the dialog.)
        ET.SubElement(item, "description").text = notes_html
    elif args.release_notes_link:
        # No embedded notes (empty/failed render) — fall back to pointing Sparkle at
        # the release page so the update dialog isn't left with a blank notes pane.
        ET.SubElement(item, f"{{{SPARKLE}}}releaseNotesLink").text = args.release_notes_link
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = args.version
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = args.short_version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = args.min_system
    ET.SubElement(item, "pubDate").text = formatdate(localtime=False)
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", args.url)
    enclosure.set(f"{{{SPARKLE}}}edSignature", ed_sig)
    enclosure.set("length", length)
    enclosure.set("type", "application/octet-stream")

    # Insert before the first existing <item> (newest first).
    children = list(channel)
    insert_at = len(children)
    for i, child in enumerate(children):
        if child.tag == "item":
            insert_at = i
            break
    channel.insert(insert_at, item)

    ET.indent(tree, space="  ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    print(f"appcast updated: {args.short_version} (build {args.version})")


if __name__ == "__main__":
    main()
