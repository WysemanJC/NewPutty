#!/usr/bin/env python3

# Build a modern macOS .icns file for PuTTY.app.
#
# The PuTTY artwork (rendered by icons/mkicon.py as RGBA PAM files) is
# placed on a macOS-style rounded-square background with the standard
# margins, so it sits correctly alongside other apps in the Dock and
# Finder, and is not put in a grey box by newer versions of macOS. Each
# size is stored as a PNG, which is what macOS uses at every size.
#
# Usage: mkicns.py output.icns size:art.pam [size:art.pam ...]
#
# Each 'size' is the full icon size in pixels; 'art.pam' is the artwork
# to centre on it, rendered at the size given by art_size() below.
# Uses only the Python standard library.

import struct
import sys
import zlib

# The icns chunk types that hold a PNG of each pixel size. 16@2x and
# 32@2x are separate types from 32 and 64.
CHUNK_TYPES = {
    16: [b"icp4"],
    32: [b"icp5", b"ic11"],
    64: [b"icp6", b"ic12"],
    128: [b"ic07"],
    256: [b"ic08", b"ic13"],
    512: [b"ic09", b"ic14"],
    1024: [b"ic10"],
}

# Proportions from Apple's macOS app icon grid: an 824-pixel rounded
# square, with a corner radius of about 185, centred on a 1024 canvas.
BODY = 824 / 1024
RADIUS = 185 / 824

def art_size(size):
    """The size the artwork should be rendered at for a given icon size."""
    return max(1, int(size * 0.6 + 0.5))

def read_pam(fname):
    with open(fname, "rb") as f:
        data = f.read()
    end = data.index(b"ENDHDR\n") + len(b"ENDHDR\n")
    header = {}
    for line in data[:end].decode("ASCII").split("\n")[1:]:
        parts = line.split()
        if len(parts) == 2:
            header[parts[0]] = parts[1]
    assert header["TUPLTYPE"] == "RGB_ALPHA" and header["MAXVAL"] == "255"
    w, h = int(header["WIDTH"]), int(header["HEIGHT"])
    pixels = data[end:]
    assert len(pixels) == w * h * 4
    return w, h, pixels

def rounded_rect_coverage(px, py, cx, cy, half, radius):
    """Fraction of the pixel centred at (px, py) inside the rounded square."""
    dx = max(abs(px - cx) - (half - radius), 0.0)
    dy = max(abs(py - cy) - (half - radius), 0.0)
    if dx == 0.0 or dy == 0.0:
        dist = max(abs(px - cx), abs(py - cy)) - half
    else:
        dist = (dx * dx + dy * dy) ** 0.5 - radius
    return min(max(0.5 - dist, 0.0), 1.0)

def background(size):
    """The rounded square, with a soft shadow beneath it, as RGBA floats."""
    cx = cy = size / 2
    half = size * BODY / 2
    radius = size * BODY * RADIUS
    shadow_off = size * 0.01
    shadow_blur = max(size * 0.012, 0.5)
    top = (0.98, 0.98, 0.99)
    bottom = (0.80, 0.82, 0.86)
    edge = (0.62, 0.64, 0.68)
    out = []
    for y in range(size):
        py = y + 0.5
        t = min(max((py - (cy - half)) / (2 * half), 0.0), 1.0)
        fill = tuple(a + (b - a) * t for a, b in zip(top, bottom))
        row = []
        for x in range(size):
            px = x + 0.5
            cov = rounded_rect_coverage(px, py, cx, cy, half, radius)
            # A one-pixel-ish darker rim keeps the edge crisp on a light
            # background.
            inner = rounded_rect_coverage(px, py, cx, cy,
                                          half - max(size / 512, 0.5),
                                          radius - max(size / 512, 0.5))
            rim = cov - inner
            colour = tuple(f * (1 - rim) + e * rim
                           for f, e in zip(fill, edge)) if cov else fill
            if cov < 1.0:
                # Shadow: a blurred copy of the shape, offset downwards.
                dx = max(abs(px - cx) - (half - radius), 0.0)
                dy = max(abs(py - shadow_off - cy) - (half - radius), 0.0)
                dist = (dx * dx + dy * dy) ** 0.5 - radius
                t = min(max(1.0 - dist / (shadow_blur * 3), 0.0), 1.0)
                sa = 0.22 * t * t
                a = cov + sa * (1 - cov)
                if a > 0:
                    colour = tuple(c * cov / a for c in colour)
                row.append((colour[0], colour[1], colour[2], a))
            else:
                row.append((colour[0], colour[1], colour[2], 1.0))
        out.append(row)
    return out

def composite(bg, size, art):
    aw, ah, pixels = art
    ox = (size - aw) // 2
    oy = (size - ah) // 2
    for y in range(ah):
        row = bg[oy + y]
        base = y * aw * 4
        for x in range(aw):
            r, g, b, a = pixels[base + 4 * x: base + 4 * x + 4]
            if a == 0:
                continue
            sa = a / 255
            dr, dg, db, da = row[ox + x]
            oa = sa + da * (1 - sa)
            row[ox + x] = (
                (r / 255 * sa + dr * da * (1 - sa)) / oa,
                (g / 255 * sa + dg * da * (1 - sa)) / oa,
                (b / 255 * sa + db * da * (1 - sa)) / oa,
                oa)
    return bg

def png(size, image):
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data +
                struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))
    raw = bytearray()
    for row in image:
        raw.append(0)
        for r, g, b, a in row:
            raw += bytes(min(255, max(0, int(v * 255 + 0.5)))
                         for v in (r, g, b, a))
    return (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(bytes(raw), 9)) +
            chunk(b"IEND", b""))

def main(args):
    if len(args) < 2 or args[0] in ("-h", "--help"):
        sys.stderr.write("usage: mkicns.py output.icns size:art.pam ...\n")
        return 1
    if args[0] == "--art-size":
        print(art_size(int(args[1])))
        return 0
    output = args[0]
    chunks = []
    for arg in args[1:]:
        size, fname = arg.split(":", 1)
        size = int(size)
        art = read_pam(fname)
        data = png(size, composite(background(size), size, art))
        for kind in CHUNK_TYPES[size]:
            chunks.append(struct.pack(">4sI", kind, len(data) + 8) + data)
    body = b"".join(chunks)
    with open(output, "wb") as f:
        f.write(struct.pack(">4sI", b"icns", len(body) + 8) + body)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
