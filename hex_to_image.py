#!/usr/bin/env python3
"""
hex_to_image.py -- reconstruct the three channel-split images from the
testbench's output hex files, using image_meta.txt to know the real
width/height and to crop off any padding pixels added by image_to_hex.py.

Usage:
    python hex_to_image.py [results_dir] [meta_path]

Produces red.png, green.png, blue.png in the current directory.
"""
import sys, os
from PIL import Image

def read_meta(meta_path):
    with open(meta_path) as f:
        lines = [l.strip() for l in f if l.strip()]
    width, height, real_pixels, total_pixels = (int(x) for x in lines[:4])
    return width, height, real_pixels, total_pixels

def load_channel_image(hex_path, width, height, real_pixels):
    img = Image.new("RGB", (width, height))
    with open(hex_path) as f:
        lines = [l.strip() for l in f if l.strip()]

    if len(lines) < real_pixels:
        print(f"WARNING: {hex_path} has {len(lines)} lines, expected at least {real_pixels}")

    for i in range(real_pixels):
        word = int(lines[i], 16)
        r = word & 0xFF
        g = (word >> 8) & 0xFF
        b = (word >> 16) & 0xFF
        x, y = i % width, i // width
        img.putpixel((x, y), (r, g, b))
    return img

def main(results_dir=".", meta_path="image_meta.txt"):
    width, height, real_pixels, total_pixels = read_meta(meta_path)
    print(f"Reconstructing {width}x{height} ({real_pixels} real pixels, "
          f"{total_pixels-real_pixels} padding pixels discarded)")

    for name in ("red", "green", "blue"):
        hex_path = os.path.join(results_dir, f"results_{name}.hex")
        if not os.path.exists(hex_path):
            print(f"Missing {hex_path}, skipping.")
            continue
        img = load_channel_image(hex_path, width, height, real_pixels)
        out_path = f"{name}.png"
        img.save(out_path)
        print(f"Saved {out_path}")

if __name__ == "__main__":
    results_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    meta_path = sys.argv[2] if len(sys.argv) > 2 else "image_meta.txt"
    main(results_dir, meta_path)
