#!/usr/bin/env python3
"""Generates the PartyBeacons textures (32-bit uncompressed TGA).

Both textures are white shapes with a baked black outline. The addon tints
them with the class color; tinting multiplies, so the outline stays black.

Usage: python3 tools/make_media.py PartyBeacons/media
"""
import math
import struct
import sys
from pathlib import Path

SS = 4  # supersampling per axis for anti-aliasing


def write_tga(path, size, pixel):
    """pixel(x, y) -> (r, g, b, a) floats 0..1, with y growing upward."""
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 8)
    rows = bytearray()
    for y in range(size):  # bottom-left origin: first row written is the bottom one
        for x in range(size):
            r, g, b, a = pixel(x, y)
            rows += bytes(int(round(max(0.0, min(1.0, v)) * 255)) for v in (b, g, r, a))
    Path(path).write_bytes(header + rows)


def sampled(size, shade):
    """shade(u, v) -> (white, alpha) per sample; u, v in pixels from the center."""
    def pixel(x, y):
        white = alpha = 0.0
        for sy in range(SS):
            for sx in range(SS):
                u = x + (sx + 0.5) / SS - size / 2
                v = y + (sy + 0.5) / SS - size / 2
                w, a = shade(u, v)
                white += w * a
                alpha += a
        n = SS * SS
        if alpha == 0:
            return (0, 0, 0, 0)
        level = white / alpha
        return (level, level, level, alpha / n)
    return pixel


def disc(size=64, outline=4.0):
    outer = size / 2 - 0.5
    inner = outer - outline

    def shade(u, v):
        r = math.hypot(u, v)
        if r > outer:
            return (0, 0)
        return (1 if r <= inner else 0, 1)
    return sampled(size, shade)


def arrow(size=32, outline=3.0):
    # Upward-pointing triangle, centered in the texture.
    tip = (0.0, size * 0.36)
    left = (-size * 0.34, -size * 0.26)
    right = (size * 0.34, -size * 0.26)
    edges = [(tip, left), (left, right), (right, tip)]

    def inside_distance(u, v):
        """Distance to the nearest edge if inside the triangle, else -1."""
        nearest = None
        for (ax, ay), (bx, by) in edges:
            ex, ey = bx - ax, by - ay
            cross = ex * (v - ay) - ey * (u - ax)
            if cross < 0:
                return -1
            d = cross / math.hypot(ex, ey)
            nearest = d if nearest is None else min(nearest, d)
        return nearest

    def shade(u, v):
        d = inside_distance(u, v)
        if d < 0:
            return (0, 0)
        return (1 if d >= outline else 0, 1)
    return sampled(size, shade)


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    write_tga(out / "disc.tga", 64, disc())
    write_tga(out / "arrow.tga", 32, arrow())
    print("wrote", out / "disc.tga", "and", out / "arrow.tga")


if __name__ == "__main__":
    main()
