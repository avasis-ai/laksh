#!/usr/bin/env python3
"""
Render frames for website/media/laksh-promo.gif — Laksh-style dark UI mock (no deps).
Run: python3 scripts/render-website-promo.py
Requires: ffmpeg on PATH.
"""
from __future__ import annotations

import os
import struct
import subprocess
import sys
import tempfile

W, H = 720, 400
FRAMES = 36
FPS = 10


def clamp(v: int) -> int:
    return max(0, min(255, v))


def frame_rgb(n: int, x: int, y: int) -> tuple[int, int, int]:
    t = n / max(1, FRAMES - 1)
    pulse = 0.5 + 0.5 * __import__("math").sin(t * 6.28318 * 1.2 + x * 0.02)

    # Base #080808
    r, g, b = 8, 8, 8

    # Title bar
    if y < 26:
        r, g, b = 14, 14, 14
        if 10 < x < 30 and 10 < y < 18:
            r, g, b = 255, 95, 87
        if 34 < x < 54 and 10 < y < 18:
            r, g, b = 254, 188, 46
        if 58 < x < 78 and 10 < y < 18:
            r, g, b = 40, 200, 64

    elif y >= 26:
        # Sidebar
        if x < 148:
            r, g, b = 10, 10, 11
            row = (y - 40) // 22
            if 0 <= row < 4 and 12 < x < 136:
                active = row == (n // 9) % 4
                br = 22 if active else 16
                r, g, b = br, br, br + (2 if active else 0)
                if active:
                    r = min(40, r + 8)
                    g = min(50, g + 18)

        # Main: three columns
        else:
            col_w = (W - 148) // 3
            cx = 148 + (n % 3) * col_w
            col_idx = (x - 148) // col_w
            # column headers
            if 30 < y < 48 and x > 148:
                r, g, b = 60, 58, 55

            # cards
            for ci in range(3):
                ox = 158 + ci * col_w
                if x < ox or x > ox + col_w - 20:
                    continue
                base_y = 58 + ci * 52
                if base_y < y < base_y + 42:
                    r, g, b = 18, 18, 19
                    # highlight "running" column middle
                    if ci == 1:
                        glow = int(30 * pulse)
                        r = clamp(12 + glow // 3)
                        g = clamp(28 + glow)
                        b = clamp(18 + glow // 2)
                    # moving dot
                    dx = ox + 14 + int((n * 3 + ci * 7) % (col_w - 40))
                    dy = base_y + 14
                    if (x - dx) ** 2 + (y - dy) ** 2 < 36:
                        r, g, b = 127, 176, 105

            # fake terminal block bottom
            if y > H - 110 and x > 158:
                r, g, b = 10, 10, 12
                # scanline
                scan = int((t * 120 + y * 0.3) % 40)
                if abs((y - (H - 95)) - scan) < 2:
                    r, g, b = 30, 45, 32
                # prompt line
                if H - 78 < y < H - 58 and 170 < x < 400:
                    r, g, b = 127, 176, 105

    return r, g, b


def write_ppm(path: str, n: int) -> None:
    header = f"P6\n{W} {H}\n255\n".encode()
    buf = bytearray(header)
    for y in range(H):
        for x in range(W):
            r, g, b = frame_rgb(n, x, y)
            buf.extend((r, g, b))
    with open(path, "wb") as f:
        f.write(buf)


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    media_dir = os.path.join(root, "website", "media")
    out_gif = os.path.join(media_dir, "laksh-promo.gif")
    out_poster = os.path.join(media_dir, "laksh-promo-poster.png")
    os.makedirs(media_dir, exist_ok=True)

    tmp = tempfile.mkdtemp(prefix="laksh-promo-")
    try:
        for i in range(FRAMES):
            write_ppm(os.path.join(tmp, f"f{i:03d}.ppm"), i)

        pattern = os.path.join(tmp, "f%03d.ppm")
        cmd = [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-framerate",
            str(FPS),
            "-i",
            pattern,
            "-filter_complex",
            "[0:v]palettegen=stats_mode=diff[p];[0:v][p]paletteuse=dither=bayer:bayer_scale=3",
            "-loop",
            "0",
            out_gif,
        ]
        subprocess.run(cmd, check=True, cwd=tmp)

        poster = os.path.join(tmp, "f000.ppm")
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-hide_banner",
                "-loglevel",
                "error",
                "-i",
                poster,
                "-frames:v",
                "1",
                out_poster,
            ],
            check=True,
        )
    finally:
        for name in os.listdir(tmp):
            os.unlink(os.path.join(tmp, name))
        os.rmdir(tmp)

    print(out_gif, file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
