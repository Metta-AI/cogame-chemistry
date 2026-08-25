#!/usr/bin/env python3
"""Render every board asset Chemistry ships into ``data/``.

Two halves:

* The CHARACTER and PROP art is nano-banana (``gen_source_sheets.py`` ->
  ``source/*.png``, ``split_sheets.py`` -> ``cut/*.png``): the eight cogs, the
  five molecules, the food token, the three vats and the five vents. This
  script only keys, scales and tints those cuts.
* The TILE art -- floor, wall, reactor pad, home plate, the reaction flash --
  is drawn procedurally here with Pillow, because a tiling surface wants exact
  seams rather than a render.

This generator does NOT own the cog/molecule/vat/vent silhouettes: those come
from ``scripts/art/cut/`` and ultimately from the committed source sheets.

    python3 scripts/art/gen_chemistry_art.py

Deterministic: the same inputs always produce the same bytes, so the committed
PNGs are reproducible. CI never runs it -- the outputs are committed.
"""
from __future__ import annotations

import math
import os
import random

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

import split_sheets

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DATA = os.path.join(ROOT, "data")
LOCKER = os.path.join(ROOT, "client", "art", "lockerroom")

CELL = 48
PAD = CELL * 3

COLORS = ["red", "orange", "yellow", "lime",
          "lightblue", "blue", "pink", "white"]
SPECIES = ["resin", "spark", "brine", "glitter", "quartz"]
REACTORS = ["amber", "beryl", "cobalt"]

TINT = {
    "amber": (217, 160, 43),
    "beryl": (62, 160, 138),
    "cobalt": (74, 122, 214),
}


def fit(image: Image.Image, size: int) -> Image.Image:
    scale = size / max(image.size)
    return image.resize(
        (max(1, round(image.width * scale)), max(1, round(image.height * scale))),
        Image.LANCZOS)


def canvas(size: int, image: Image.Image, dy: int = 0) -> Image.Image:
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(image, ((size - image.width) // 2,
                      (size - image.height) // 2 + dy), image)
    return out


def hue_to_pink(image: Image.Image) -> Image.Image:
    """The pink cog came back red on every generation; rotate it in one place.

    A plain channel remap keeps the render's shading and the cyan visor while
    moving the plating from crimson to bubblegum.
    """
    out = image.copy()
    pixels = out.load()
    for y in range(out.height):
        for x in range(out.width):
            r, g, b, a = pixels[x, y]
            if a == 0 or b > r:
                continue
            pixels[x, y] = (min(255, r + 20), g, min(255, b + (r - b) * 3 // 5), a)
    return out


# ---------------------------------------------------------------------------
# Procedural tiles
# ---------------------------------------------------------------------------

def floor_tile() -> Image.Image:
    rng = random.Random(20260825)
    tile = Image.new("RGBA", (CELL, CELL), (74, 78, 84, 255))
    draw = ImageDraw.Draw(tile)
    for _ in range(220):
        x, y = rng.randrange(CELL), rng.randrange(CELL)
        shade = rng.randrange(-11, 14)
        draw.point((x, y), fill=(74 + shade, 78 + shade, 84 + shade, 255))
    draw.line((0, 0, CELL - 1, 0), fill=(88, 93, 100, 255))
    draw.line((0, 0, 0, CELL - 1), fill=(88, 93, 100, 255))
    draw.line((0, CELL - 1, CELL - 1, CELL - 1), fill=(58, 61, 66, 255))
    draw.line((CELL - 1, 0, CELL - 1, CELL - 1), fill=(58, 61, 66, 255))
    return tile


def wall_tile() -> Image.Image:
    tile = Image.new("RGBA", (CELL, CELL), (13, 15, 19, 255))
    draw = ImageDraw.Draw(tile)
    draw.rectangle((2, 2, CELL - 3, CELL - 3), fill=(24, 27, 33, 255))
    draw.rectangle((2, 2, CELL - 3, CELL - 3), outline=(46, 51, 60, 255))
    draw.line((3, 3, CELL - 4, 3), fill=(64, 71, 82, 255))
    for x, y in ((8, 8), (CELL - 9, 8), (8, CELL - 9), (CELL - 9, CELL - 9)):
        draw.ellipse((x - 3, y - 3, x + 3, y + 3), fill=(70, 78, 90, 255))
        draw.ellipse((x - 1, y - 1, x + 1, y + 1), fill=(18, 20, 25, 255))
    return tile


def pad_tile() -> Image.Image:
    tile = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    draw = ImageDraw.Draw(tile)
    draw.rectangle((0, 0, CELL - 1, CELL - 1), fill=(58, 54, 40, 190))
    for offset in range(-CELL, CELL * 2, 16):
        draw.polygon(
            [(offset, CELL), (offset + 8, CELL), (offset + 8 + CELL, 0),
             (offset + CELL, 0)],
            fill=(120, 104, 46, 120))
    draw.rectangle((0, 0, CELL - 1, CELL - 1), outline=(150, 132, 60, 160))
    return tile


def home_tile() -> Image.Image:
    tile = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    draw = ImageDraw.Draw(tile)
    draw.rectangle((5, 5, CELL - 6, CELL - 6), outline=(150, 156, 168, 150),
                   width=2)
    draw.line((5, 5, 14, 5), fill=(210, 216, 226, 220), width=3)
    draw.line((5, 5, 5, 14), fill=(210, 216, 226, 220), width=3)
    draw.line((CELL - 6, CELL - 6, CELL - 15, CELL - 6),
              fill=(210, 216, 226, 220), width=3)
    draw.line((CELL - 6, CELL - 6, CELL - 6, CELL - 15),
              fill=(210, 216, 226, 220), width=3)
    return tile


def flash_sprite() -> Image.Image:
    out = Image.new("RGBA", (PAD, PAD), (0, 0, 0, 0))
    draw = ImageDraw.Draw(out)
    centre = PAD / 2
    for radius in range(int(centre), 8, -4):
        alpha = int(150 * (1 - radius / centre) ** 1.6)
        draw.ellipse((centre - radius, centre - radius,
                      centre + radius, centre + radius),
                     fill=(255, 246, 214, alpha))
    for index in range(12):
        angle = index * math.pi / 6
        draw.line((centre, centre,
                   centre + math.cos(angle) * centre * 0.92,
                   centre + math.sin(angle) * centre * 0.92),
                  fill=(255, 252, 232, 130), width=4)
    return out.filter(ImageFilter.GaussianBlur(2))


# ---------------------------------------------------------------------------
# Derived sprites
# ---------------------------------------------------------------------------

def vat_states(cut: Image.Image, name: str) -> list[Image.Image]:
    """cold / warm / bright. The glass goes grey at charge 0 and brightens as
    the cycle runs, which is the board half of the plate gauge."""
    base = canvas(PAD, fit(cut, PAD - 6))
    cold = ImageEnhance.Color(base).enhance(0.15)
    cold = ImageEnhance.Brightness(cold).enhance(0.62)
    warm = base
    glow = Image.new("RGBA", (PAD, PAD), (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow)
    tint = TINT[name]
    for radius in range(PAD // 2, 10, -6):
        alpha = int(70 * (1 - radius / (PAD / 2)) ** 1.3)
        draw.ellipse((PAD / 2 - radius, PAD / 2 - radius,
                      PAD / 2 + radius, PAD / 2 + radius),
                     fill=(tint[0], tint[1], tint[2], alpha))
    bright = Image.alpha_composite(glow.filter(ImageFilter.GaussianBlur(6)),
                                   ImageEnhance.Brightness(base).enhance(1.22))
    return [cold, warm, bright]


def carry_variant(front: Image.Image) -> Image.Image:
    """A carrying cog gets a warm rim so a full hand reads at board scale even
    before the molecule sprite over its head is legible."""
    alpha = front.getchannel("A")
    ring = Image.new("RGBA", front.size, (255, 214, 120, 0))
    ring.putalpha(alpha.filter(ImageFilter.MaxFilter(5)))
    ring = ring.filter(ImageFilter.GaussianBlur(1.5))
    return Image.alpha_composite(ring, front)


def main() -> None:
    os.makedirs(DATA, exist_ok=True)
    os.makedirs(LOCKER, exist_ok=True)

    floor_tile().save(os.path.join(DATA, "floor.png"))
    wall_tile().save(os.path.join(DATA, "wall.png"))
    pad_tile().save(os.path.join(DATA, "pad.png"))
    home_tile().save(os.path.join(DATA, "home.png"))
    flash_sprite().save(os.path.join(DATA, "flash.png"))

    cogs = dict(split_sheets.cut_sheet("cogs_a"))
    cogs.update(split_sheets.cut_sheet("cogs_b"))
    cogs["pink"] = hue_to_pink(cogs["pink"])
    for name in COLORS:
        front = canvas(CELL, fit(cogs[name], CELL - 2))
        front.save(os.path.join(DATA, f"cog_{name}_front.png"))
        carry_variant(front).save(os.path.join(DATA, f"cog_{name}_carry.png"))
        portrait = fit(cogs[name], 220)
        plate = Image.new("RGBA", (portrait.width, portrait.height), (0, 0, 0, 0))
        plate.paste(portrait, (0, 0), portrait)
        plate.save(os.path.join(LOCKER, f"{name}_1.webp"), lossless=True)

    molecules = split_sheets.cut_sheet("molecules")
    for name in SPECIES:
        canvas(32, fit(molecules[name], 30)).save(
            os.path.join(DATA, f"mol_{name}.png"))
    food = canvas(32, fit(molecules["food"], 30))
    food.save(os.path.join(DATA, "food.png"))
    ripe = ImageEnhance.Brightness(food).enhance(1.3)
    ripe = Image.alpha_composite(
        ripe.filter(ImageFilter.GaussianBlur(1.2)), food)
    ripe.save(os.path.join(DATA, "food_ripe.png"))

    vents = split_sheets.cut_sheet("vents")
    for name in SPECIES:
        canvas(CELL, fit(vents[name], CELL - 2), dy=-2).save(
            os.path.join(DATA, f"vent_{name}.png"))

    vats = split_sheets.cut_sheet("vats")
    for name in REACTORS:
        for state, image in enumerate(vat_states(vats[name], name)):
            image.save(os.path.join(DATA, f"vat_{name}_{state}.png"))

    scene = Image.open(
        os.path.join(HERE, "source", "lockerroom.png")).convert("RGB")
    scene = scene.resize((992, 926), Image.LANCZOS)
    scene.save(os.path.join(LOCKER, "bg.jpg"), quality=88)
    print(f"wrote board art into {DATA} and {LOCKER}")


if __name__ == "__main__":
    main()
