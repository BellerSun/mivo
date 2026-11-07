#!/usr/bin/env python3
"""Generate disposable B01 build assets from the canonical SVG."""
import argparse
from pathlib import Path
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--export", action="store_true", help="also export transparent PNGs, white SVG and ICO")
args = parser.parse_args()
ASSETS = ROOT / ".build" / "icons"
ASSETS.mkdir(parents=True, exist_ok=True)
source = (ROOT / "Assets" / "Logo" / "mivo.svg").read_text()
if args.export:
    (ASSETS / "mivo.svg").write_text(source)
    (ASSETS / "mivo-white.svg").write_text(source.replace('stroke="#000"', 'stroke="#fff"'))
(ASSETS / "mivo-app.svg").write_text(source.replace(
    "  <g ", '  <rect x="5" y="5" width="90" height="90" rx="20" fill="#fff"/>\n  <g ', 1
))
# Python may run under Rosetta; keep AppKit rendering native on Apple Silicon.
apple_silicon = subprocess.run(
    ["/usr/sbin/sysctl", "-n", "hw.optional.arm64"], capture_output=True, text=True
).stdout.strip() == "1"
swift = ["/usr/bin/arch", "-arm64", "/usr/bin/swift"] if apple_silicon else ["/usr/bin/swift"]
variants = ["mivo", "mivo-white", "mivo-app"] if args.export else ["mivo-app"]
subprocess.run(swift + [str(ROOT / "scripts" / "render-icons.swift"), str(ASSETS)] + variants, check=True)

# ICO entries can contain PNG payloads, preserving alpha at every resolution.
if args.export:
    sizes = [16, 24, 32, 48, 64, 128, 256]
    payloads = [(ASSETS / f"mivo-app-{size}.png").read_bytes() for size in sizes]
    offset = 6 + 16 * len(sizes)
    entries = []
    for size, data in zip(sizes, payloads):
        entries.append(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset))
        offset += len(data)
    (ASSETS / "mivo.ico").write_bytes(struct.pack("<HHH", 0, 1, len(sizes)) + b"".join(entries + payloads))

iconset = ASSETS / "Mivo.iconset"
iconset.mkdir(exist_ok=True)
for size in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        suffix = "@2x" if scale == 2 else ""
        shutil.copyfile(ASSETS / f"mivo-app-{size * scale}.png", iconset / f"icon_{size}x{size}{suffix}.png")
subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ASSETS / "Mivo.icns")], check=True)
print(f"Generated {'export and ' if args.export else ''}app icon assets in {ASSETS}")
