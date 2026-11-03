#!/usr/bin/env python3
"""Deterministic, opaque 1024-pixel NeuroAR research app icon.

Uses Python's standard library only. Run before compiling any iOS target.
No patient data, third-party artwork, remote assets, or secrets are involved.
"""
from __future__ import annotations

import json
import math
import struct
import zlib
from pathlib import Path

SIDE = 1024
BG = (9, 23, 39)
TEAL = (76, 231, 219)
MID = (38, 155, 168)
LOW = (24, 65, 83)
DARK = (17, 45, 62)
PIXELS = bytearray(bytes(BG) * (SIDE * SIDE))


def dot(cx: float, cy: float, radius: int, color: tuple[int, int, int]) -> None:
    cx = int(round(cx))
    cy = int(round(cy))
    xmin, xmax = max(0, cx - radius), min(SIDE - 1, cx + radius)
    ymin, ymax = max(0, cy - radius), min(SIDE - 1, cy + radius)
    rr = radius * radius
    rgb = bytes(color)
    for y in range(ymin, ymax + 1):
        for x in range(xmin, xmax + 1):
            if (x - cx) ** 2 + (y - cy) ** 2 <= rr:
                at = (y * SIDE + x) * 3
                PIXELS[at:at + 3] = rgb


def stroke(points: list[tuple[float, float]], width: int, color: tuple[int, int, int]) -> None:
    for a, b in zip(points, points[1:]):
        distance = math.hypot(a[0] - b[0], a[1] - b[1])
        segments = max(1, int(distance * 0.72))
        for step in range(segments + 1):
            t = step / segments
            dot(a[0] * (1-t) + b[0] * t, a[1] * (1-t) + b[1] * t, width // 2, color)


def smooth(points: list[tuple[float, float]], iterations: int = 3) -> list[tuple[float, float]]:
    for _ in range(iterations):
        result = [points[0]]
        for a, b in zip(points, points[1:]):
            result.extend([(a[0]*0.75+b[0]*0.25, a[1]*0.75+b[1]*0.25),
                           (a[0]*0.25+b[0]*0.75, a[1]*0.25+b[1]*0.75)])
        result.append(points[-1])
        points = result
    return points


def mirror(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    return [(SIDE-x, y) for x, y in points]


def arc(cx: float, cy: float, radius: float, start: int, end: int, width: int,
        color: tuple[int, int, int]) -> None:
    pts = [(cx + radius*math.cos(math.radians(i)),
            cy + radius*math.sin(math.radians(i))) for i in range(start, end+1, 2)]
    stroke(pts, width, color)


# Thin navigation rings and a contrasting, symmetrical anatomical line drawing.
arc(512, 512, 385, -175, -10, 10, LOW)
arc(512, 512, 385, 10, 175, 10, LOW)
arc(512, 512, 336, 38, 141, 7, DARK)
arc(512, 512, 336, 218, 321, 7, DARK)
left = [(503,235),(437,232),(373,255),(322,300),(286,359),(290,406),
        (248,449),(239,520),(267,586),(301,618),(297,678),(348,731),
        (399,759),(460,747),(493,707)]
stroke(smooth(left), 21, TEAL)
stroke(smooth(mirror(left)), 21, TEAL)
stroke([(512,254),(512,721)], 12, MID)

gyri = [
    [(473,301),(418,320),(385,372),(418,421),(463,434)],
    [(346,362),(365,416),(342,465),(309,490)],
    [(457,503),(406,490),(366,531),(386,570),(438,599)],
    [(329,622),(375,644),(414,638),(460,670)]
]
for path in gyri:
    stroke(smooth(path), 15, MID)
    stroke(smooth(mirror(path)), 15, MID)
for x,y,r in [(512,237,15),(512,741,15),(297,511,11),(727,511,11)]:
    dot(x, y, r, TEAL)
arc(512, 797, 49, 34, 145, 10, MID)
arc(512, 797, 49, 213, 326, 10, MID)

def chunk(kind: bytes, data: bytes) -> bytes:
    payload = kind + data
    return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload) & 0xffffffff)

raw = b"".join(b"\x00" + bytes(PIXELS[y*SIDE*3:(y+1)*SIDE*3]) for y in range(SIDE))
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", SIDE, SIDE, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))
outdir = Path("NeuroAR/Assets.xcassets/AppIcon.appiconset")
outdir.mkdir(parents=True, exist_ok=True)
out = outdir / "NeuroARIcon-1024.png"
out.write_bytes(png)
catalog = {
    "images": [{"filename": out.name, "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
    "info": {"author": "xcode", "version": 1},
}
(outdir / "Contents.json").write_text(json.dumps(catalog, indent=2) + "\n")
assert out.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
print(f"Generated NeuroAR AppIcon: 1024x1024 opaque PNG ({out.stat().st_size:,} bytes).")
