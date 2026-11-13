#!/usr/bin/python3
"""Add (or replace) one release in Sparkle's appcast.

The appcast is the file every installed copy of Remon polls. Each <item> names a version, where
to download it and the EdDSA signature of that download; Sparkle refuses anything whose signature
doesn't match the public key baked into the running app.

Called by scripts/release.sh; usable by hand to fix up an entry.
"""

import argparse
import os
import xml.etree.ElementTree as ET
from email.utils import format_datetime
from datetime import datetime, timezone

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def empty_appcast(title: str) -> ET.ElementTree:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = title
    return ET.ElementTree(rss)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--appcast", required=True)
    p.add_argument("--version", required=True, help="marketing version, e.g. 1.1")
    p.add_argument("--build", required=True, help="CFBundleVersion, e.g. 4")
    p.add_argument("--url", required=True, help="download URL of the .zip")
    p.add_argument("--signature", required=True, help="sparkle:edSignature value")
    p.add_argument("--length", required=True, help="size of the .zip in bytes")
    p.add_argument("--minimum-system-version", default="15.0")
    p.add_argument("--release-notes-url", default=None)
    p.add_argument("--title", default="Remon")
    args = p.parse_args()

    if os.path.exists(args.appcast):
        tree = ET.parse(args.appcast)
    else:
        tree = empty_appcast(args.title)
    channel = tree.getroot().find("channel")

    # Replace an entry for the same build rather than listing it twice.
    for item in channel.findall("item"):
        if item.findtext(f"{{{SPARKLE}}}version") == args.build:
            channel.remove(item)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {args.version}"
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = args.build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = args.version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = args.minimum_system_version
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    if args.release_notes_url:
        ET.SubElement(item, f"{{{SPARKLE}}}releaseNotesLink").text = args.release_notes_url
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "length": str(args.length),
        "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": args.signature,
    })

    # Newest first: Sparkle doesn't require it, but it makes the file readable.
    items = channel.findall("item")
    for existing in items:
        channel.remove(existing)
    for existing in sorted([item] + items, key=lambda e: int(e.findtext(f"{{{SPARKLE}}}version") or 0), reverse=True):
        channel.append(existing)

    ET.indent(tree, space="    ")
    os.makedirs(os.path.dirname(args.appcast) or ".", exist_ok=True)
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    print(f"Wrote {args.appcast} ({args.version}, build {args.build})")


if __name__ == "__main__":
    main()
