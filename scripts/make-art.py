#!/usr/bin/env python3
"""Draws the app icon and the DMG window art (needs Pillow and the Swift toolchain).

    python3 scripts/make-art.py

Writes App/AppIcon.icon (Icon Composer format: SVG layers on a gradient fill),
scripts/dmg/background{,@2x}.png and scripts/dmg/volume.icns (the mounted disk's icon).
The outputs are committed; rerun only to change the artwork.
"""
import json
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "App/AppIcon.icon"
DMG_DIR = ROOT / "scripts/dmg"

TOP = (86, 98, 255)      # indigo
BOTTOM = (176, 74, 230)  # violet
FONT = "/System/Library/Fonts/SFNS.ttf"

# Renders an SVG with AppKit (ImageMagick's built-in SVG renderer gets strokes and gradients wrong).
RENDER_SWIFT = """
import AppKit
let a = CommandLine.arguments
guard let img = NSImage(contentsOfFile: a[1]) else { fatalError("cannot load \\(a[1])") }
let px = Int(a[3])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
"""

# Layer artwork in the classic 1024 icon grid; the viewBox crops to the 824 squircle area,
# matching how Icon Composer places layers.
SVG_OPEN = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="100 100 824 824">'
STROKE = 'stroke="#FFFFFF" stroke-width="30" stroke-linecap="round" fill="none"'
MIC = (
    '<rect x="437" y="250" width="150" height="300" rx="75" fill="#FFFFFF"/>'
    f'<path d="M382 470A130 130 0 0 0 642 470" {STROKE}/>'
    f'<path d="M512 600V724M437 724H587" {STROKE}/>'
)
WAVES = "".join(
    f'<path d="M{512 + side * off} {400 - h // 2}V{400 + h // 2}" {STROKE}/>'
    for off, h in ((205, 164), (266, 266), (327, 123))
    for side in (-1, 1)
)


def hex_rgb(c):
    return "#%02X%02X%02X" % c


def srgb(c):
    return "srgb:" + ",".join(f"{v / 255:.5f}" for v in c) + ",1.00000"


def write_icon():
    assets = ICON / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    (assets / "mic.svg").write_text(SVG_OPEN + MIC + "</svg>\n")
    (assets / "waves.svg").write_text(SVG_OPEN + WAVES + "</svg>\n")
    spec = {
        "fill": {"linear-gradient": [srgb(TOP), srgb(BOTTOM)]},
        "groups": [
            {"layers": [{"image-name": "waves.svg", "name": "waves", "opacity": 0.6},
                        {"image-name": "mic.svg", "name": "mic"}],
             "shadow": {"kind": "neutral", "opacity": 0.5},
             "translucency": {"enabled": False, "value": 0.5}},
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    (ICON / "icon.json").write_text(json.dumps(spec, indent=2) + "\n")


def write_volume_icon():
    """A flat rendering of the same artwork (squircle on the 1024 grid) for the disk image."""
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024">'
        f'<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{hex_rgb(TOP)}"/>'
        f'<stop offset="1" stop-color="{hex_rgb(BOTTOM)}"/></linearGradient></defs>'
        '<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#g)"/>'
        f'<g opacity="0.6">{WAVES}</g>{MIC}</svg>'
    )
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "icon.svg"
        src.write_text(svg)
        iconset = Path(tmp) / "volume.iconset"
        iconset.mkdir()
        master = Path(tmp) / "master.png"
        renderer = Path(tmp) / "render.swift"
        renderer.write_text(RENDER_SWIFT)
        subprocess.run(["swift", str(renderer), str(src), str(master), "1024"], check=True)
        img = Image.open(master).convert("RGBA")
        for pt in (16, 32, 128, 256, 512):
            img.resize((pt, pt), Image.LANCZOS).save(iconset / f"icon_{pt}x{pt}.png")
            img.resize((pt * 2, pt * 2), Image.LANCZOS).save(iconset / f"icon_{pt}x{pt}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", "-o", str(DMG_DIR / "volume.icns"), str(iconset)], check=True)


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def vertical_gradient(size, top, bottom):
    w, h = size
    col = Image.new("RGB", (1, h))
    for y in range(h):
        col.putpixel((0, y), lerp(top, bottom, y / (h - 1)))
    return col.resize((w, h))


def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


def draw_background(scale):
    """660x400 pt window. Icons sit at (170, 190) and (490, 190); see scripts/dmg/settings.py."""
    w, h = 660 * scale, 400 * scale
    img = vertical_gradient((w, h), (250, 250, 255), (236, 234, 252)).convert("RGBA")
    d = ImageDraw.Draw(img)
    ink = (40, 36, 70)
    muted = (110, 106, 140)

    d.text((w // 2, 62 * scale), "Drag VoiceToText into Applications",
           font=font(22 * scale, "Semibold"), fill=ink, anchor="mm")

    # Dashed arrow between the two icon slots.
    y = 190 * scale
    x0, x1 = 252 * scale, 400 * scale
    accent = lerp(TOP, BOTTOM, 0.5) + (255,)
    dash, gap = 12 * scale, 9 * scale
    x = x0
    while x < x1 - 18 * scale:
        d.rounded_rectangle((x, y - 3 * scale, min(x + dash, x1 - 18 * scale), y + 3 * scale), 3 * scale, fill=accent)
        x += dash + gap
    d.polygon([(x1 + 6 * scale, y), (x1 - 20 * scale, y - 16 * scale), (x1 - 20 * scale, y + 16 * scale)], fill=accent)

    note = "First launch: System Settings  ›  Privacy & Security  ›  Open Anyway"
    d.text((w // 2, 352 * scale), note, font=font(13 * scale, "Regular"), fill=muted, anchor="mm")
    return img


def write_backgrounds():
    DMG_DIR.mkdir(parents=True, exist_ok=True)
    draw_background(1).save(DMG_DIR / "background.png")
    draw_background(2).save(DMG_DIR / "background@2x.png")


if __name__ == "__main__":
    write_icon()
    write_backgrounds()
    write_volume_icon()
    print(f"wrote {ICON.relative_to(ROOT)} and {DMG_DIR.relative_to(ROOT)}/")
