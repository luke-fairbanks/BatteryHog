#!/usr/bin/env python3
"""Pack PNG iconset members into a modern ICNS file.

macOS 26's ``iconutil`` can reject iconsets that it just extracted itself. This
small standard-library fallback writes the documented chunked ICNS container
without re-encoding any PNG data.
"""

import os
import struct
import sys


CHUNKS = [
    (b"icp4", "icon_16x16.png"),
    (b"ic11", "icon_16x16@2x.png"),
    (b"icp5", "icon_32x32.png"),
    (b"ic12", "icon_32x32@2x.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic13", "icon_128x128@2x.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic14", "icon_256x256@2x.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
]


def pack(iconset, output):
    chunks = []
    for kind, filename in CHUNKS:
        path = os.path.join(iconset, filename)
        with open(path, "rb") as handle:
            png = handle.read()
        if not png.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError("not a PNG: " + path)
        chunks.append(kind + struct.pack(">I", len(png) + 8) + png)
    body = b"".join(chunks)
    with open(output, "wb") as handle:
        handle.write(b"icns" + struct.pack(">I", len(body) + 8) + body)


def main(argv):
    if len(argv) != 3:
        print("usage: make_icns.py ICONSET OUTPUT.icns", file=sys.stderr)
        return 2
    pack(argv[1], argv[2])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
