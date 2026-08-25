#!/usr/bin/env python3
"""Generate the Chemistry board-art source sheets with nano-banana.

Reproduces every file under ``scripts/art/source/``. The sheets are committed,
so CI never runs this; it exists so the art is reproducible rather than
mysterious (``playbooks/art-nanobanana.md``).

    GEMINI_API_KEY=... python3 scripts/art/gen_source_sheets.py [name ...]

The key is passed ONLY as the ``x-goog-api-key`` header, never printed, never
written to a file and never put in a URL.
"""
from __future__ import annotations

import base64
import json
import os
import sys
import urllib.error
import urllib.request

MODEL = "gemini-2.5-flash-image"
ENDPOINT = (
    "https://generativelanguage.googleapis.com/v1beta/models/"
    f"{MODEL}:generateContent"
)
HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "source")
# The canonical Softmax cog, inherited from the paintbot starter: passed as an
# inline_data part so every sheet is anchored to the same character design.
ANCHOR = os.path.join(
    os.path.dirname(os.path.dirname(HERE)), "scripts", "art", "source",
    "cog_reference.png")

CHROMA = (
    "Background: perfectly flat, solid, uniform pure bright green (#00FF00), "
    "no shadows, no gradients, no floor, no ground plane -- it will be "
    "chroma-keyed out. No text, no labels, no captions, no borders."
)

SHEETS = {
    "cogs_a": (
        "Using this wheeled robot character (\"cog\") as the exact character "
        "design reference, draw FOUR of these cogs side by side in one row, "
        "evenly spaced, same size, full body, front-facing, standing on their "
        "wheels, same clean cartoon rendering, each holding nothing. They are "
        "lab workers on a chemistry floor: each wears a small chest harness "
        "with a chemical flask clipped to it. Recolour the plating, keeping "
        "the cyan smile visor on every one: "
        "1st CRIMSON RED (#d94f3d), 2nd ORANGE (#e2843a), "
        "3rd YELLOW (#dcc23a), 4th LIME GREEN (#7cc44a). " + CHROMA),
    "cogs_b": (
        "Using this wheeled robot character (\"cog\") as the exact character "
        "design reference, draw FOUR of these cogs side by side in one row, "
        "evenly spaced, same size, full body, front-facing, standing on their "
        "wheels, same clean cartoon rendering, each holding nothing. They are "
        "lab workers on a chemistry floor: each wears a small chest harness "
        "with a chemical flask clipped to it. Recolour the plating, keeping "
        "the cyan smile visor on every one: "
        "1st PALE SKY BLUE (#7fc4e8), 2nd DEEP BLUE (#3f6fd0), "
        "3rd BUBBLEGUM PINK (#e07fb8) -- pink, not red -- , "
        "4th BONE WHITE (#e8e4dc). " + CHROMA),
    "molecules": (
        "Draw SIX separate small objects in one evenly spaced row, same "
        "scale, chunky readable cartoon game-icon style with a thick dark "
        "outline, viewed straight on. Each must be tellable apart BY SHAPE "
        "alone, not only by colour: "
        "1st a TRIANGULAR amber resin crystal, matte, warm honey brown; "
        "2nd a four-pointed electric SPARK star, bright cyan white, glowing; "
        "3rd a round teal BRINE droplet with a flat top, matte; "
        "4th a many-faceted hyper-glossy pink GLITTER gem with sparkles, "
        "obviously precious and useless; "
        "5th a hexagonal hyper-glossy violet QUARTZ prism with sparkles; "
        "6th a warm golden BREAD ROLL food token with a scored crust. "
        "Leave a wide empty margin on all four sides; no object may touch "
        "or cross the edge of the image. " + CHROMA),
    "vats": (
        "Draw THREE industrial chemical reactor vats side by side in one row, "
        "evenly spaced, same size, viewed from a high three-quarter angle "
        "looking down, chunky readable cartoon game-art style with thick dark "
        "outlines. Each is a squat riveted steel tank with a big round glass "
        "window in the front and a heavy bolted rim. The liquid glowing "
        "inside is: 1st warm AMBER gold, 2nd deep TEAL green, 3rd bright "
        "COBALT blue. All three sit in a straight horizontal row at the "
        "same height, not overlapping, with a wide empty margin around the "
        "row. " + CHROMA),
    "vents": (
        "Draw FIVE industrial floor pipe vents side by side in one row, "
        "evenly spaced, same size, viewed from a high three-quarter angle "
        "looking down, chunky readable cartoon game-art style with thick dark "
        "outlines. Each is a short steel pipe elbow rising out of the floor "
        "with a bolted collar, venting a small puff. The collar colours are: "
        "1st warm honey brown, 2nd bright cyan, 3rd teal, 4th glossy pink, "
        "5th glossy violet. " + CHROMA),
    "lockerroom": (
        "Draw a wide cinematic illustration of an empty industrial chemistry "
        "workshop interior: three big riveted steel reactor vats glowing "
        "amber, teal and blue along the back wall, pipes and valves overhead, "
        "a scuffed concrete floor with painted yellow hazard lanes, warm "
        "practical lighting, a few crates of coloured crystals stacked at the "
        "side. Chunky readable cartoon game-art style, no characters, no "
        "text, no labels."),
}


def generate(name: str, prompt: str, anchor: bool = True) -> None:
    parts = []
    if anchor and os.path.exists(ANCHOR):
        with open(ANCHOR, "rb") as handle:
            parts.append({"inline_data": {
                "mime_type": "image/png",
                "data": base64.b64encode(handle.read()).decode(),
            }})
    parts.append({"text": prompt})
    body = {
        "contents": [{"parts": parts}],
        "generationConfig": {"responseModalities": ["IMAGE"]},
    }
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={
            "x-goog-api-key": os.environ["GEMINI_API_KEY"],
            "content-type": "application/json",
        },
    )
    try:
        response = json.load(urllib.request.urlopen(request, timeout=180))
    except urllib.error.HTTPError as error:
        sys.stderr.write(
            f"{name}: HTTP {error.code}\n{error.read().decode()[:800]}\n")
        raise SystemExit(1)
    part = next(
        p for p in response["candidates"][0]["content"]["parts"]
        if "inlineData" in p)
    os.makedirs(SOURCE, exist_ok=True)
    out = os.path.join(SOURCE, f"{name}.png")
    with open(out, "wb") as handle:
        handle.write(base64.b64decode(part["inlineData"]["data"]))
    print(f"wrote {out}")


def main() -> None:
    wanted = sys.argv[1:] or list(SHEETS)
    for name in wanted:
        if name not in SHEETS:
            raise SystemExit(f"unknown sheet: {name}")
        generate(name, SHEETS[name], anchor=name.startswith("cogs"))


if __name__ == "__main__":
    main()
