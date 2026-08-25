#!/usr/bin/env python3
"""Chroma-key and split the nano-banana source sheets.

Gemini does not return alpha and the "pure green" it draws comes back as
*some* green with a tinted edge, so the backdrop colour is taken as the median
of the image border and flood-filled from the border (green accents INSIDE a
character survive). The row is then split on the emptiest columns, each part is
trimmed to its ink and padded to a square.

Imported by ``gen_chemistry_art.py``; runnable on its own for inspection:

    python3 scripts/art/split_sheets.py            # writes scripts/art/cut/
"""
from __future__ import annotations

import os
from collections import deque

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "source")
CUT = os.path.join(HERE, "cut")

# sheet -> the part names, left to right.
SHEETS = {
    "cogs_a": ["red", "orange", "yellow", "lime"],
    "cogs_b": ["lightblue", "blue", "pink", "white"],
    "molecules": ["resin", "spark", "brine", "glitter", "quartz", "food"],
    "vats": ["amber", "beryl", "cobalt"],
    "vents": ["resin", "spark", "brine", "glitter", "quartz"],
}

TOLERANCE = 60

# Sheets whose row was drawn on a diagonal: after the cut each part can carry a
# sliver of its neighbour, so keep only its own largest connected blob.
ISOLATE = {"vats"}


def _median_border(image: Image.Image) -> tuple[int, int, int]:
    pixels = image.load()
    width, height = image.size
    samples = []
    for x in range(0, width, max(1, width // 64)):
        samples.append(pixels[x, 0][:3])
        samples.append(pixels[x, height - 1][:3])
    for y in range(0, height, max(1, height // 64)):
        samples.append(pixels[0, y][:3])
        samples.append(pixels[width - 1, y][:3])
    channels = []
    for index in range(3):
        values = sorted(sample[index] for sample in samples)
        channels.append(values[len(values) // 2])
    return tuple(channels)


def chroma_key(image: Image.Image) -> Image.Image:
    """Flood-fill the backdrop from the border and make it transparent."""
    image = image.convert("RGBA")
    width, height = image.size
    pixels = image.load()
    backdrop = _median_border(image)

    def matches(x: int, y: int) -> bool:
        r, g, b, _ = pixels[x, y]
        return (abs(r - backdrop[0]) + abs(g - backdrop[1]) +
                abs(b - backdrop[2])) <= TOLERANCE

    seen = bytearray(width * height)
    queue: deque[tuple[int, int]] = deque()
    for x in range(width):
        for y in (0, height - 1):
            if matches(x, y):
                queue.append((x, y))
                seen[y * width + x] = 1
    for y in range(height):
        for x in (0, width - 1):
            if matches(x, y):
                queue.append((x, y))
                seen[y * width + x] = 1
    while queue:
        x, y = queue.popleft()
        pixels[x, y] = (0, 0, 0, 0)
        for dx, dy in ((0, -1), (1, 0), (0, 1), (-1, 0)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < width and 0 <= ny < height:
                if not seen[ny * width + nx] and matches(nx, ny):
                    seen[ny * width + nx] = 1
                    queue.append((nx, ny))
    return image


def _ink_per_column(image: Image.Image) -> list[int]:
    alpha = image.getchannel("A")
    width, height = image.size
    data = alpha.tobytes()
    return [sum(1 for y in range(height) if data[y * width + x] > 24)
            for x in range(width)]


def _segments(ink: list[int]) -> list[tuple[int, int]]:
    spans = []
    start = None
    for x, value in enumerate(ink):
        if value > 0 and start is None:
            start = x
        elif value == 0 and start is not None:
            spans.append((start, x))
            start = None
    if start is not None:
        spans.append((start, len(ink)))
    return spans


def split_row(image: Image.Image, count: int) -> list[Image.Image]:
    """Split a keyed row into `count` parts, left to right.

    Column gaps first; when the sheet drew the row on a diagonal and two parts
    touch, the widest remaining segment is cut at its thinnest column, which is
    deterministic and needs no hand-tuned coordinates.
    """
    ink = _ink_per_column(image)
    spans = [span for span in _segments(ink) if span[1] - span[0] > 8]
    while len(spans) < count:
        widest = max(range(len(spans)), key=lambda i: spans[i][1] - spans[i][0])
        start, stop = spans[widest]
        margin = (stop - start) // 4
        window = range(start + margin, stop - margin)
        cut = min(window, key=lambda x: (ink[x], abs(x - (start + stop) // 2)))
        spans[widest:widest + 1] = [(start, cut), (cut, stop)]
    spans.sort()
    if len(spans) > count:
        spans = sorted(spans, key=lambda s: s[1] - s[0])[-count:]
        spans.sort()
    return [image.crop((start, 0, stop, image.height)) for start, stop in spans]


def largest_blob(image: Image.Image) -> Image.Image:
    """Keep only the largest connected run of opaque pixels."""
    width, height = image.size
    alpha = image.getchannel("A").tobytes()
    label = [0] * (width * height)
    best_id, best_size, current = 0, 0, 0
    for start in range(width * height):
        if alpha[start] <= 24 or label[start]:
            continue
        current += 1
        size = 0
        queue = deque([start])
        label[start] = current
        while queue:
            index = queue.popleft()
            size += 1
            x, y = index % width, index // width
            for dx, dy in ((0, -1), (1, 0), (0, 1), (-1, 0)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < width and 0 <= ny < height:
                    n = ny * width + nx
                    if alpha[n] > 24 and not label[n]:
                        label[n] = current
                        queue.append(n)
        if size > best_size:
            best_size, best_id = size, current
    out = image.copy()
    pixels = out.load()
    for index in range(width * height):
        if label[index] != best_id:
            pixels[index % width, index // width] = (0, 0, 0, 0)
    return out


def trim_square(image: Image.Image, pad: int = 4) -> Image.Image:
    box = image.getbbox()
    if box is None:
        return image
    cropped = image.crop(box)
    side = max(cropped.size) + pad * 2
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(
        cropped,
        ((side - cropped.width) // 2, (side - cropped.height) // 2))
    return square


def cut_sheet(name: str) -> dict[str, Image.Image]:
    path = os.path.join(SOURCE, f"{name}.png")
    keyed = chroma_key(Image.open(path))
    parts = split_row(keyed, len(SHEETS[name]))
    if name in ISOLATE:
        parts = [largest_blob(part) for part in parts]
    return {
        label: trim_square(part)
        for label, part in zip(SHEETS[name], parts)
    }


def main() -> None:
    os.makedirs(CUT, exist_ok=True)
    for sheet in SHEETS:
        for label, part in cut_sheet(sheet).items():
            out = os.path.join(CUT, f"{sheet}_{label}.png")
            part.save(out)
            print(f"wrote {out} {part.size}")


if __name__ == "__main__":
    main()
