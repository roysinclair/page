#!/usr/bin/env python3
"""Turns the raw screenshots in ./out/ into the published files.

    python3 compress.py

- docs/images/<name>.png             (README / GitHub; palette-quantised with libimagequant when over budget)
- website/public/img/showcase/<name>.webp   (website; "hero@web" is the 2880x1440 hero, published as hero.webp)
- website/public/img/og/<page>.webp         (website social cards, from "og-<page>": no README copy)

Needs Pillow and `imagequant` (pip install pillow imagequant).
"""
import glob
import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
DOCS = os.path.abspath(os.path.join(HERE, ".."))
WEB = os.path.abspath(os.path.join(HERE, "..", "..", "..", "website", "public", "img", "showcase"))
OG = os.path.abspath(os.path.join(WEB, "..", "og"))
PNG_BUDGET = 1_400_000  # bytes; the brief caps each PNG at 1.5 MB


def quantise(img, colours=256):
    import imagequant
    return imagequant.quantize_pil_image(img.convert("RGBA"), dithering_level=1.0, max_colors=colours,
                                         min_quality=0, max_quality=100)


def main():
    os.makedirs(WEB, exist_ok=True)
    for raw in sorted(glob.glob(os.path.join(HERE, "out", "*.png"))):
        name = os.path.splitext(os.path.basename(raw))[0]
        if name.startswith("_") or name.startswith("screen-"):  # local previews; product-shots.py reads screen-* from out/
            continue
        img = Image.open(raw).convert("RGB")
        if name.startswith("og-"):
            img.save(os.path.join(OG, name[3:] + ".webp"), "WEBP", quality=86, method=6)
            print(f"og/{name[3:]}.webp {os.path.getsize(os.path.join(OG, name[3:] + '.webp')) // 1024} KB")
            continue
        if name.endswith("@web"):
            base = name[:-4]
            img.save(os.path.join(WEB, base + ".webp"), "WEBP", quality=86, method=6)
            continue
        png = os.path.join(DOCS, name + ".png")
        img.save(png, optimize=True)
        if os.path.getsize(png) > PNG_BUDGET:
            quantise(img).save(png, optimize=True)
        if name != "hero":  # the web hero is the larger @web shot
            img.save(os.path.join(WEB, name + ".webp"), "WEBP", quality=86, method=6)
        print(f"{name}.png {os.path.getsize(png) // 1024} KB")
    for f in sorted(glob.glob(os.path.join(WEB, "*.webp"))):
        print(f"showcase/{os.path.basename(f)} {os.path.getsize(f) // 1024} KB")


if __name__ == "__main__":
    main()
