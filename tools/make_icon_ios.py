#!/usr/bin/env python3
"""Gera o ícone do iOS (pilha de blocos do Empilha) em todos os tamanhos do AppIcon.appiconset.

Uso: python3 tools/make_icon_ios.py ios/Runner/Assets.xcassets/AppIcon.appiconset
"""
import json
import os
import sys

from PIL import Image, ImageDraw

MASTER = 2048  # desenha grande e reduz (suaviza as bordas)

BG_TOP, BG_BOTTOM = (14, 38, 54), (8, 20, 33)
# (topo, base, contorno) de cada bloco: base 3, meio 2, topo 1
BLOCKS = [
    ((90, 218, 235), (24, 160, 182), (160, 238, 247)),
    ((255, 200, 64), (214, 146, 0), (255, 224, 140)),
    ((244, 112, 156), (196, 40, 98), (250, 170, 200)),
    ((178, 220, 130), (116, 168, 70), (212, 238, 178)),
    ((124, 138, 214), (70, 84, 168), (176, 186, 236)),
    ((250, 140, 40), (200, 84, 0), (252, 190, 130)),
]


def vgrad(size, top, bottom):
    w, h = size
    img = Image.new("RGB", size)
    px = img.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = c
    return img


def rounded_mask(size, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius, fill=255)
    return m


def draw_block(canvas, x, y, s, colors):
    top, bottom, border_c = colors
    border = max(2, round(s * 0.09))
    radius = round(s * 0.2)
    # contorno claro
    canvas.paste(border_c, (x, y), rounded_mask((s, s), radius))
    # miolo com degradê
    inner = s - 2 * border
    fill = vgrad((inner, inner), top, bottom)
    canvas.paste(fill, (x + border, y + border), rounded_mask((inner, inner), max(radius - border, 1)))


def make_master():
    # iOS aplica os cantos arredondados sozinho: fundo quadrado, sem transparência
    img = vgrad((MASTER, MASTER), BG_TOP, BG_BOTTOM)
    s = round(MASTER * 0.27)
    gap = round(s * 0.08)
    total = 3 * s + 2 * gap
    x0 = (MASTER - total) // 2
    y0 = (MASTER - total) // 2
    cx = MASTER // 2
    draw_block(img, cx - s // 2, y0, s, BLOCKS[5])  # topo
    for i in range(2):  # meio
        draw_block(img, cx - s - gap // 2 + i * (s + gap), y0 + s + gap, s, BLOCKS[3 + i])
    for i in range(3):  # base
        draw_block(img, x0 + i * (s + gap), y0 + 2 * (s + gap), s, BLOCKS[i])
    return img


# (tamanho em pontos, escala, idiom)
ENTRIES = [
    (20, 1, "ipad"), (20, 2, "iphone"), (20, 2, "ipad"), (20, 3, "iphone"),
    (29, 1, "ipad"), (29, 2, "iphone"), (29, 2, "ipad"), (29, 3, "iphone"),
    (40, 1, "ipad"), (40, 2, "iphone"), (40, 2, "ipad"), (40, 3, "iphone"),
    (60, 2, "iphone"), (60, 3, "iphone"),
    (76, 1, "ipad"), (76, 2, "ipad"),
    (83.5, 2, "ipad"),
    (1024, 1, "ios-marketing"),
]


def fmt(n):
    return str(int(n)) if float(n).is_integer() else str(n)


def main(dest):
    os.makedirs(dest, exist_ok=True)
    master = make_master()
    images, cache = [], {}
    for size, scale, idiom in ENTRIES:
        px = round(size * scale)
        name = f"Icon-App-{fmt(size)}x{fmt(size)}@{scale}x.png"
        if idiom == "ios-marketing":
            name = "Icon-App-1024x1024@1x.png"
        if name not in cache:
            master.resize((px, px), Image.LANCZOS).convert("RGB").save(os.path.join(dest, name))
            cache[name] = True
        images.append({
            "size": f"{fmt(size)}x{fmt(size)}",
            "idiom": idiom,
            "filename": name,
            "scale": f"{scale}x",
        })
    with open(os.path.join(dest, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"version": 1, "author": "xcode"}}, f, indent=2)
    print(f"Ícones iOS gerados em {dest} ({len(cache)} arquivos)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "ios/Runner/Assets.xcassets/AppIcon.appiconset")
