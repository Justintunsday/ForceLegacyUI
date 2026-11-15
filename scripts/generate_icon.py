#!/usr/bin/env python3
"""Rasterize a small code-defined navigation-window icon; no external dependencies."""
from pathlib import Path
import json
import struct
import zlib

root = Path(__file__).resolve().parents[1] / "ForceLegacyUI/Resources/Assets.xcassets"
destination = root / "AppIcon.appiconset"
destination.mkdir(parents=True, exist_ok=True)

def rounded(x, y, left, top, right, bottom, radius):
    if x < left or x >= right or y < top or y >= bottom: return False
    dx = max(left + radius - x, 0, x - (right - radius - 1))
    dy = max(top + radius - y, 0, y - (bottom - radius - 1))
    return dx * dx + dy * dy <= radius * radius

raw = bytearray()
for y in range(1024):
    raw.append(0)
    for x in range(1024):
        color = (22, 87, 181)
        if rounded(x, y, 204, 154, 820, 870, 58): color = (249, 251, 255)
        if 205 <= x < 819 and 269 <= y < 273: color = (200, 214, 235)
        if rounded(x, y, 256, 200, 286, 230, 8): color = (22, 87, 181)
        if rounded(x, y, 364, 204, 664, 226, 8): color = (22, 87, 181)
        for index in range(4):
            if rounded(x, y, 256, 335 + index * 118, 316, 395 + index * 118, 14): color = (214, 229, 249)
            if rounded(x, y, 346, 342 + index * 118, 724, 358 + index * 118, 7): color = (42, 80, 132)
            if rounded(x, y, 346, 376 + index * 118, 630, 388 + index * 118, 5): color = (160, 181, 210)
        raw.extend(color)

def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)

png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1024, 1024, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
(destination / "AppIcon.png").write_bytes(png)
(destination / "Contents.json").write_text(json.dumps({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
(root / "Contents.json").write_text('{"info":{"author":"xcode","version":1}}\n')
print("Generated opaque 1024px icon.")
