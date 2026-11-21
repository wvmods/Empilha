#!/usr/bin/env python3
"""Gera o ícone do Empilha (pilha de blocos 3-2-1) sem dependências externas.

Uso:
  python3 tools/make_icon.py android/app/src/main/res      # Android
  python3 tools/make_icon.py --ico windows/runner/resources/app_icon.ico   # Windows
  python3 tools/make_icon.py --png icon_1024.png           # PNG avulso
"""
import math
import os
import struct
import sys
import zlib

# fundo e cores dos blocos (ordem: base 3, meio 2, topo 1)
BG_TOP = (14, 38, 54)
BG_BOT = (8, 20, 33)
COLORS = [
    (38, 198, 218), (255, 179, 0), (236, 64, 122),   # base
    (156, 204, 101), (92, 107, 192),                 # meio
    (239, 108, 0),                                   # topo
]


def write_png(path, w, h, px):
    open(path, "wb").write(png_bytes(w, h, px))


def png_bytes(w, h, px):
    raw = b"".join(b"\x00" + bytes(px[y * w * 4:(y + 1) * w * 4]) for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def sdf_rr(px, py, x0, y0, w, h, r):
    qx = abs(px - (x0 + w / 2)) - (w / 2 - r)
    qy = abs(py - (y0 + h / 2)) - (h / 2 - r)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r


def cov(d):
    return max(0.0, min(1.0, 0.5 - d))


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def clamp01(v):
    return max(0.0, min(1.0, v))


def block_color(base, py, y0, b, d):
    t = clamp01((py - y0) / b)
    col = mix(mix(base, (255, 255, 255), 0.22), mix(base, (0, 0, 0), 0.30), t)
    if d < -b * 0.12:
        col = mix(col, (255, 255, 255), clamp01(1 - (py - y0) / (b * 0.45)) * 0.18)
    return col


def layout(s, scale):
    b = s * scale
    gap = b * 0.08
    cx = s / 2
    total = 3 * b + 2 * gap
    top = (s - total) / 2
    blocks = []
    for i in range(3):   # base
        blocks.append((cx - 1.5 * b - gap + i * (b + gap), top + 2 * (b + gap)))
    for i in range(2):   # meio
        blocks.append((cx - b - gap / 2 + i * (b + gap), top + (b + gap)))
    blocks.append((cx - b / 2, top))  # topo
    return b, blocks


def render(size, with_bg, scale, round_bg=True):
    s = size
    b, blocks = layout(s, scale)
    out = bytearray(s * s * 4)
    for y in range(s):
        row_bg = mix(BG_TOP, BG_BOT, y / s)
        for x in range(s):
            px, py = x + 0.5, y + 0.5
            if with_bg:
                a = cov(sdf_rr(px, py, 0, 0, s, s, s * 0.22)) if round_bg else 1.0
                col = row_bg
            else:
                a, col = 0.0, (0, 0, 0)
            for (bx, by), base in zip(blocks, COLORS):
                if px < bx - 1 or px > bx + b + 1 or py < by - 1 or py > by + b + 1:
                    continue
                d = sdf_rr(px, py, bx, by, b, b, b * 0.2)
                c = cov(d)
                if c <= 0:
                    continue
                bc = block_color(base, py, by, b, d)
                na = c + a * (1 - c)
                col = tuple((bc[i] * c + col[i] * a * (1 - c)) / na for i in range(3))
                a = na
            i = (y * s + x) * 4
            out[i], out[i + 1], out[i + 2] = (int(round(v)) for v in col)
            out[i + 3] = int(round(a * 255))
    return out


def write_ico(path, sizes=(16, 24, 32, 48, 64, 128, 256)):
    """ICO com PNGs embutidos (aceito pelo Windows Vista em diante)."""
    imgs = [(n, png_bytes(n, n, render(n, True, 0.27))) for n in sizes]
    head = struct.pack("<HHH", 0, 1, len(imgs))
    offset = 6 + 16 * len(imgs)
    entries, data = b"", b""
    for n, png in imgs:
        entries += struct.pack("<BBBBHHII", n % 256, n % 256, 0, 0, 1, 32, len(png), offset)
        data += png
        offset += len(png)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    open(path, "wb").write(head + entries + data)
    print("Ícone do Windows gerado em", path)


DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def android(res):
    for name, f in DENSITIES.items():
        d = os.path.join(res, f"mipmap-{name}")
        os.makedirs(d, exist_ok=True)
        legacy = int(48 * f)
        write_png(os.path.join(d, "ic_launcher.png"), legacy, legacy, render(legacy, True, 0.2))
        fg = int(108 * f)
        write_png(os.path.join(d, "ic_launcher_foreground.png"), fg, fg, render(fg, False, 0.17))
    d = os.path.join(res, "mipmap-anydpi-v26")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "ic_launcher.xml"), "w") as fh:
        fh.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@color/ic_launcher_background"/>\n'
            '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
            "</adaptive-icon>\n"
        )
    d = os.path.join(res, "values")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "ic_launcher_background.xml"), "w") as fh:
        fh.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            "<resources>\n"
            '    <color name="ic_launcher_background">#0E2636</color>\n'
            "</resources>\n"
        )
    print("Ícones gerados em", res)


def main():
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "--ico":
        write_ico(a[1])
    elif len(a) == 2 and a[0] == "--png":
        write_png(a[1], 1024, 1024, render(1024, True, 0.27))
        print("PNG gerado em", a[1])
    else:
        android(a[0] if a else "res")


if __name__ == "__main__":
    main()
