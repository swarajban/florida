# /// script
# requires-python = ">=3.11"
# dependencies = ["cairosvg==2.8.2", "pillow==12.0.0"]
# ///
"""Run with `uv run apple/Design/generate-assets.py`; no font or network needed after install."""
import json
from pathlib import Path
from xml.etree import ElementTree

import cairosvg
from PIL import Image

root = Path(__file__).resolve().parent
catalog = root / "Assets.xcassets"
info = {"author": "xcode", "version": 1}


def manifest(directory, **values):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "Contents.json").write_text(json.dumps({**values, "info": info}, indent=2) + "\n")


manifest(catalog)
palette = {
    "Paper": ("FAF9F5", "1A1E1B"),
    "Panel": ("F2F1EB", "202620"),
    "Ink": ("252924", "EEEEE6"),
    "Rule": ("E1E2D9", "363E34"),
}
for name, variants in palette.items():
    colors = []
    for index, hex_color in enumerate(variants):
        entry = {
            "idiom": "universal",
            "color": {
                "color-space": "srgb",
                "components": {
                    **{channel: f"0x{hex_color[offset:offset + 2]}" for channel, offset in zip(("red", "green", "blue"), (0, 2, 4))},
                    "alpha": "1.000",
                },
            },
        }
        if index:
            entry["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
        colors.append(entry)
    manifest(catalog / f"{name}.colorset", colors=colors)

for name in ("FloridaMark", "FloridaWordmark"):
    directory = catalog / f"{name}.imageset"
    manifest(directory, images=[{"idiom": "universal", "filename": f"{name}.pdf"}],
             properties={"preserves-vector-representation": True, "template-rendering-intent": "template"})
    cairosvg.svg2pdf(url=str(root / f"{name}.svg"), write_to=str(directory / f"{name}.pdf"))

mark = ElementTree.parse(root / "FloridaMark.svg").find("{http://www.w3.org/2000/svg}path").attrib["d"]


def icon(paper, ink, mac=False):
    background = '<rect x="52" y="52" width="920" height="920" rx="208"' if mac else '<rect width="1024" height="1024"'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024">'
            f'{background} fill="#{paper}"/>'
            f'<path d="{mark}" transform="translate(128 128) scale(3)" fill="#{ink}"/></svg>').encode()


ios = root.parent / "iOS/Assets.xcassets/AppIcon.appiconset"
images = []
for suffix, paper, ink in (("", "FAF9F5", "252924"), ("-dark", "1A1E1B", "EEEEE6")):
    filename = f"AppIcon-1024{suffix}.png"
    image = {"idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": filename}
    if suffix:
        image["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
    images.append(image)
    cairosvg.svg2png(bytestring=icon(paper, ink), write_to=str(ios / filename))
    # App Store icons must have no alpha channel, even when every alpha value is opaque.
    with Image.open(ios / filename) as output:
        output.convert("RGB").save(ios / filename)
manifest(ios, images=images)

mac = root.parent / "macOS/Assets.xcassets/AppIcon.appiconset"
manifest(mac.parent)
mac.mkdir(parents=True, exist_ok=True)
images = []
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        filename = f"icon-{size}@{scale}x.png"
        cairosvg.svg2png(bytestring=icon("FAF9F5", "252924", mac=True),
                        output_width=size * scale, output_height=size * scale, write_to=str(mac / filename))
        images.append({"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x", "filename": filename})
manifest(mac, images=images)
