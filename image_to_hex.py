#!/usr/bin/env python3
"""
image_to_hex.py -- convert ANY input photo, at its natural resolution, into
the pixel-stimulus hex file the testbench reads via $readmemh.

Usage:
    python image_to_hex.py <input_image_path> [output_hex_path]

Does NOT force a resize. Uses whatever resolution the input image already
is. Pads with black (0,0,0) pixels up to the next multiple of 4 if needed
(the array processes 4 pixels per batch), so the pixel count always divides
cleanly. Writes a companion metadata file (image_meta.txt) recording the
real width, height, and padded total pixel count, so the testbench can
loop the correct number of times and the reconstruction script can crop
the padding back off.

Word format (matches act_mem's lane convention: lane 0 = low byte):
    bits [7:0]   = R   (lane 0)
    bits [15:8]  = G   (lane 1)
    bits [23:16] = B   (lane 2)
    bits [31:24] = 0   (lane 3, unused -- the K_real=3 padding lane)
"""
import sys
from PIL import Image

BATCH = 4  # array width -- pixels per accelerator run

def convert(input_path, output_path="act_stim.hex", meta_path="image_meta.txt"):
    img = Image.open(input_path).convert("RGB")
    width, height = img.size
    real_pixels = width * height

    remainder = real_pixels % BATCH
    pad_pixels = (BATCH - remainder) if remainder != 0 else 0
    total_pixels = real_pixels + pad_pixels

    lines = []
    for y in range(height):
        for x in range(width):
            r, g, b = img.getpixel((x, y))
            word = (0 << 24) | (b << 16) | (g << 8) | r
            lines.append(f"{word:08X}")

    for _ in range(pad_pixels):
        lines.append("00000000")

    with open(output_path, "w") as f:
        f.write("\n".join(lines) + "\n")

    with open(meta_path, "w") as f:
        f.write(f"{width}\n{height}\n{real_pixels}\n{total_pixels}\n")

    est_batches = total_pixels // BATCH
    est_cycles = est_batches * 3 * 14

    print(f"Image: {width}x{height} = {real_pixels} pixels")
    if pad_pixels:
        print(f"Padded with {pad_pixels} black pixel(s) -> {total_pixels} total")
    print(f"Batches per channel: {est_batches}  (x3 channels = {est_batches*3} runs)")
    print(f"Rough cycle estimate (no weight reuse): ~{est_cycles:,} cycles")
    print(f"Wrote {output_path} and {meta_path}")
    return output_path, meta_path

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python image_to_hex.py <input_image> [output_hex]")
        sys.exit(1)
    out = sys.argv[2] if len(sys.argv) > 2 else "act_stim.hex"
    convert(sys.argv[1], out)
