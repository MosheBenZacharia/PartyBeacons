#!/usr/bin/env python3
"""Draws the Party Beacons icon: a ringed marker with an arrow above it.

Writes a 64px TGA for the in-game addon list and a 400px PNG for the
CurseForge project avatar.

Usage: python3 tools/make_icon.py PartyBeacons/media/icon.tga release/avatar.png
"""
import math
import struct
import sys
import zlib
from pathlib import Path

SS = 3  # supersampling per axis

BACKGROUND = (0.09, 0.12, 0.17)
OUTLINE = (0.0, 0.0, 0.0)
AMBER = (1.0, 0.62, 0.18)
CORE = (0.16, 0.22, 0.30)
SPARK = (1.0, 0.93, 0.80)


def rounded_square(u, v, half, radius):
    """Signed distance to a rounded square centered on the origin (negative inside)."""
    qx, qy = abs(u) - (half - radius), abs(v) - (half - radius)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    return outside + min(max(qx, qy), 0.0) - radius


def triangle_depth(u, v, points):
    """Distance to the nearest edge when inside the triangle, else -1."""
    nearest = None
    for i in range(3):
        ax, ay = points[i]
        bx, by = points[(i + 1) % 3]
        ex, ey = bx - ax, by - ay
        cross = ex * (v - ay) - ey * (u - ax)
        if cross < 0:
            return -1.0
        depth = cross / math.hypot(ex, ey)
        nearest = depth if nearest is None else min(nearest, depth)
    return nearest


def shade(u, v):
    """u, v in -1..1 with v growing upward. Returns (r, g, b, a)."""
    if rounded_square(u, v, 0.96, 0.22) > 0:
        return (0.0, 0.0, 0.0, 0.0)
    color = BACKGROUND

    # Marker disc, a little below center.
    r = math.hypot(u, v + 0.24)
    if r <= 0.50:
        if r > 0.44:
            color = OUTLINE
        elif r > 0.30:
            color = AMBER
        elif r > 0.26:
            color = OUTLINE
        elif r > 0.10:
            color = CORE
        else:
            color = SPARK

    # Arrow above the disc, pointing up (counter-clockwise points).
    depth = triangle_depth(u, v, [(0.0, 0.84), (-0.30, 0.40), (0.30, 0.40)])
    if depth >= 0:
        color = AMBER if depth >= 0.055 else OUTLINE
    return (color[0], color[1], color[2], 1.0)


def render(size):
    """Rows top to bottom, each a list of (r, g, b, a) bytes."""
    rows = []
    for y in range(size):
        row = []
        for x in range(size):
            acc = [0.0, 0.0, 0.0, 0.0]
            for sy in range(SS):
                for sx in range(SS):
                    u = ((x + (sx + 0.5) / SS) / size) * 2 - 1
                    v = 1 - ((y + (sy + 0.5) / SS) / size) * 2
                    r, g, b, a = shade(u, v)
                    acc[0] += r * a
                    acc[1] += g * a
                    acc[2] += b * a
                    acc[3] += a
            if acc[3] == 0:
                row.append((0, 0, 0, 0))
            else:
                row.append(tuple(int(round(255 * c / acc[3])) for c in acc[:3]) + (int(round(255 * acc[3] / (SS * SS))),))
        rows.append(row)
    return rows


def write_tga(path, rows):
    size = len(rows)
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 8)
    body = bytearray()
    for row in reversed(rows):  # bottom-left origin
        for r, g, b, a in row:
            body += bytes((b, g, r, a))
    Path(path).write_bytes(header + body)


def write_png(path, rows):
    size = len(rows)
    raw = bytearray()
    for row in rows:
        raw.append(0)
        for pixel in row:
            raw += bytes(pixel)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    Path(path).write_bytes(png)


def main():
    tga_path, png_path = Path(sys.argv[1]), Path(sys.argv[2])
    tga_path.parent.mkdir(parents=True, exist_ok=True)
    png_path.parent.mkdir(parents=True, exist_ok=True)
    write_tga(tga_path, render(64))
    write_png(png_path, render(400))
    print("wrote", tga_path, "and", png_path)


if __name__ == "__main__":
    main()
