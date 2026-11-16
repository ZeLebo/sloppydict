#!/usr/bin/env python3
"""Build the macOS icon from the checked-in PNG using system tools."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = ROOT / "Resources/AppIcon.png"
    iconset = ROOT / "build/AppIcon.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    for points in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            pixels = points * scale
            suffix = "@2x" if scale == 2 else ""
            output = iconset / f"icon_{points}x{points}{suffix}.png"
            subprocess.run(
                ["sips", "--resampleHeightWidth", str(pixels), str(pixels), str(source), "--out", str(output)],
                check=True, stdout=subprocess.DEVNULL,
            )
    subprocess.run(["iconutil", "--convert", "icns", "--output", str(ROOT / "build/AppIcon.icns"), str(iconset)], check=True)
    print("Built build/AppIcon.icns")


if __name__ == "__main__":
    main()
