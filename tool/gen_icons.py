#!/usr/bin/env python3
"""Generate the Smart App Lock launcher icons (legacy + adaptive).

Pure Python standard library (zlib/struct) — no Pillow, no Android SDK.
Run from anywhere:

    python3 tool/gen_icons.py

Outputs:
    android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png
    android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher_foreground.png

Design: white padlock with a navy keyhole on a deep-navy rounded square
(legacy icons) or on a transparent canvas (adaptive foreground layer).
Anti-aliased via 4x4 supersampling.
"""

import math
import os
import struct
import zlib

# Brand colors (RGBA, 0-255)
BG_NAVY = (16, 26, 60)      # #101A3C
FG_WHITE = (255, 255, 255)  # #FFFFFF

# Legacy icons: square launcher icons per density bucket (px).
LEGACY_SIZES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
# Adaptive foreground layers: 108dp canvas per density bucket (px).
ADAPTIVE_SIZES = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES_DIR = os.path.join(PROJECT_ROOT, "android", "app", "src", "main", "res")


# ---------------------------------------------------------------------------
# Padlock geometry in unit space (0..1), centered canvas.
# ---------------------------------------------------------------------------
SHACKLE_CY = 0.38
SHACKLE_OUTER_R = 0.155
SHACKLE_INNER_R = 0.088

BODY_X0, BODY_X1 = 0.305, 0.695
BODY_Y0, BODY_Y1 = 0.375, 0.70
BODY_CORNER_R = 0.08

KEYHOLE_CY = 0.50
KEYHOLE_R = 0.027
KEYHOLE_SLOT_X0, KEYHOLE_SLOT_X1 = 0.474, 0.526
KEYHOLE_SLOT_Y0, KEYHOLE_SLOT_Y1 = 0.50, 0.625


def _in_rounded_rect(x, y, x0, y0, x1, y1, r):
    """Point-in-rounded-rect test (unit space)."""
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def in_lock_body(x, y):
    return _in_rounded_rect(x, y, BODY_X0, BODY_Y0, BODY_X1, BODY_Y1, BODY_CORNER_R)


def in_lock_shackle(x, y):
    """Upper half of an annulus = the padlock shackle (upside-down U)."""
    d = math.hypot(x - 0.5, y - SHACKLE_CY)
    return y <= SHACKLE_CY and SHACKLE_INNER_R <= d <= SHACKLE_OUTER_R


def in_keyhole(x, y):
    """Circle + slot punched out of the lock body (shows the background)."""
    if math.hypot(x - 0.5, y - KEYHOLE_CY) <= KEYHOLE_R:
        return True
    return KEYHOLE_SLOT_X0 <= x <= KEYHOLE_SLOT_X1 and KEYHOLE_SLOT_Y0 <= y <= KEYHOLE_SLOT_Y1


def in_glyph(x, y):
    """White lock pixels (body or shackle, minus the keyhole)."""
    if in_keyhole(x, y):
        return False
    return in_lock_body(x, y) or in_lock_shackle(x, y)


# ---------------------------------------------------------------------------
# PNG writer
# ---------------------------------------------------------------------------
def png_bytes(size, sample_color):
    """Render a size*size RGBA image; sample_color(x, y) -> (r, g, b, a)."""
    width = height = size
    ss = 4  # 4x4 supersampling per pixel
    raw = bytearray()
    for py in range(height):
        raw.append(0)  # PNG filter type: None
        for px in range(width):
            r_sum = g_sum = b_sum = a_sum = 0
            for sy in range(ss):
                for sx in range(ss):
                    x = (px + (sx + 0.5) / ss) / width
                    y = (py + (sy + 0.5) / ss) / height
                    r, g, b, a = sample_color(x, y)
                    r_sum += r * a
                    g_sum += g * a
                    b_sum += b * a
                    a_sum += a
            n = ss * ss
            if a_sum == 0:
                raw.extend((0, 0, 0, 0))
            else:
                a = a_sum / n
                raw.extend((
                    round(r_sum / a_sum),
                    round(g_sum / a_sum),
                    round(b_sum / a_sum),
                    round(a),
                ))

    def chunk(tag, data):
        out = struct.pack(">I", len(data)) + tag + data
        out += struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        return out

    signature = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return (
        signature
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


# ---------------------------------------------------------------------------
# Icon painters
# ---------------------------------------------------------------------------
def legacy_pixel(x, y):
    """Navy rounded square + white lock with navy keyhole (transparent corners)."""
    if not _in_rounded_rect(x, y, 0.0, 0.0, 1.0, 1.0, 0.22):
        return (*BG_NAVY, 0)  # transparent corner
    if in_glyph(x, y):
        return (*FG_WHITE, 255)
    return (*BG_NAVY, 255)


def adaptive_pixel(x, y):
    """White lock only; keyhole stays transparent so the navy background
    color layer shows through. Glyph scaled to the adaptive-icon safe zone."""
    g = 0.60  # glyph scale -> stays inside the central 66dp safe zone
    gx = (x - 0.5) / g + 0.5
    gy = (y - 0.5) / g + 0.5
    if in_glyph(gx, gy):
        return (*FG_WHITE, 255)
    return (*BG_NAVY, 0)  # transparent


def write_icons():
    generated = []

    for density, size in LEGACY_SIZES.items():
        path = os.path.join(RES_DIR, f"mipmap-{density}", "ic_launcher.png")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(png_bytes(size, legacy_pixel))
        generated.append(path)

    for density, size in ADAPTIVE_SIZES.items():
        path = os.path.join(RES_DIR, f"mipmap-{density}", "ic_launcher_foreground.png")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(png_bytes(size, adaptive_pixel))
        generated.append(path)

    return generated


def main():
    for path in write_icons():
        rel = os.path.relpath(path, PROJECT_ROOT)
        print(f"  wrote {rel}")
    print(f"\nGenerated {len(LEGACY_SIZES) + len(ADAPTIVE_SIZES)} icons.")


if __name__ == "__main__":
    main()
