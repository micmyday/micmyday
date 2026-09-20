#!/usr/bin/env python3
"""Adds one release to the Sparkle appcast.

Kept apart from release.sh because editing XML with shell tools is how appcasts
end up malformed, and a malformed appcast is invisible until every user's
updater silently stops working.

The new item goes first and existing ones are left untouched: Sparkle picks the
newest it understands, and older entries still serve anyone on a Mac too old for
the current release.
"""

import argparse
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
EMPTY = """<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="{ns}" version="2.0">
    <channel>
        <title>MicMyDay</title>
        <description>Updates for MicMyDay.</description>
        <language>en</language>
    </channel>
</rss>
""".format(ns=SPARKLE_NS)


def parse_signature(line: str) -> tuple[str, str]:
    """Pulls the signature and length out of what `sign_update` prints.

    It emits a ready-made attribute fragment rather than plain values, so this
    reads them back out instead of assuming a format that may change.
    """
    signature = re.search(r'sparkle:edSignature="([^"]+)"', line)
    length = re.search(r'length="(\d+)"', line)
    if not signature:
        sys.exit(f"could not find a signature in: {line!r}")
    return signature.group(1), length.group(1) if length else ""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--version", required=True, help="eg 1.1.0")
    parser.add_argument("--build", required=True, help="CFBundleVersion, the number Sparkle compares")
    parser.add_argument("--url", required=True)
    parser.add_argument("--length", required=True)
    parser.add_argument("--signature-line", required=True)
    parser.add_argument("--minimum-system", default="14.0")
    args = parser.parse_args()

    signature, signed_length = parse_signature(args.signature_line)
    length = signed_length or args.length

    path = Path(args.appcast)
    if not path.exists():
        path.write_text(EMPTY)

    ElementTree.register_namespace("sparkle", SPARKLE_NS)
    tree = ElementTree.parse(path)
    channel = tree.getroot().find("channel")
    if channel is None:
        sys.exit("appcast has no <channel>")

    for existing in channel.findall("item"):
        version = existing.find(f"{{{SPARKLE_NS}}}shortVersionString")
        if version is not None and version.text == args.version:
            sys.exit(
                f"{args.version} is already in the appcast. "
                "Bump the version, or remove that entry first."
            )

    item = ElementTree.Element("item")
    ElementTree.SubElement(item, "title").text = args.version
    ElementTree.SubElement(item, "pubDate").text = datetime.now(timezone.utc).strftime(
        "%a, %d %b %Y %H:%M:%S +0000"
    )
    # Sparkle compares `version`; `shortVersionString` is only ever shown.
    ElementTree.SubElement(item, f"{{{SPARKLE_NS}}}version").text = args.build
    ElementTree.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = args.version
    ElementTree.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = args.minimum_system
    # Release notes travel inside the appcast, so the update dialogue can say
    # what changed without sending anyone to a website.
    notes = ElementTree.SubElement(item, "description")
    notes.text = f"<h3>MicMyDay {args.version}</h3>\n<ul>\n  <li>WRITE THE RELEASE NOTES HERE</li>\n</ul>"

    enclosure = ElementTree.SubElement(item, "enclosure")
    enclosure.set("url", args.url)
    enclosure.set("length", length)
    enclosure.set("type", "application/octet-stream")
    enclosure.set(f"{{{SPARKLE_NS}}}edSignature", signature)

    # Before the first existing item, but after the channel's own metadata, so
    # the newest release leads and <description>/<language> stay at the top
    # where a reader expects them.
    children = list(channel)
    first_item = next((i for i, child in enumerate(children) if child.tag == "item"), len(children))
    channel.insert(first_item, item)
    ElementTree.indent(tree, space="    ")

    # ElementTree does not preserve CDATA: it parses the contents as text and
    # re-escapes them on write. Left alone, every previously published entry
    # would have its release notes escaped a little more on each release until
    # Sparkle displayed literal <h3> tags. So each item's notes are swapped for
    # a token before writing and the real CDATA block is put back afterwards,
    # which restores existing entries as well as the new one.
    tokens: dict[str, str] = {}
    for index, existing in enumerate(channel.findall("item")):
        notes = existing.find("description")
        if notes is None or not notes.text:
            continue
        token = f"__MICMYDAY_NOTES_{index}__"
        tokens[token] = notes.text
        notes.text = token

    tree.write(path, encoding="utf-8", xml_declaration=True)

    text = path.read_text()
    for token, body in tokens.items():
        text = text.replace(token, f"<![CDATA[{body}]]>")
    path.write_text(text)

    print(f"added {args.version} (build {args.build}) to {path}")
    print("Remember to write the release notes before publishing.")


if __name__ == "__main__":
    main()
