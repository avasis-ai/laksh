#!/usr/bin/env python3
"""
Laksh website promo GIF — high-motion “ad” (Framer-style easing, depth, glow).

Creative motifs (OpenClaw / agent main, GLM 5.1 — 2026):
  spring stacks, pulse wave across columns, parallax drift, sidebar choreography,
  orbit-to-grid energy, terminal typewriter.

Requires: Pillow, ffmpeg on PATH.
Prefer: .venv/bin/python after `python3 -m venv .venv && .venv/bin/pip install pillow`

Encoding (GIF): ffmpeg ``palettegen`` + ``paletteuse`` (error diffusion) — see
https://ffmpeg.org/ffmpeg-filters.html#palettegen-1
Optional sharper / smaller GIFs: https://www.lcdf.org/gifsicle/ (post-process).

Rendering: draws at 2× resolution, downsamples with Lanczos for sharper UI text;
MP4 uses a lower CRF than before for cleaner motion.

Run from repo root:
  .venv/bin/python scripts/render-website-promo.py
  # or:  python3 scripts/render-website-promo.py  (if pillow is global)
"""
from __future__ import annotations

import math
import os
import random
import subprocess
import sys
import tempfile

try:
    from PIL import Image, ImageDraw, ImageFont, ImageFilter
except ImportError:
    print(
        "Install Pillow:  python3 -m venv .venv && .venv/bin/pip install pillow",
        file=sys.stderr,
    )
    raise SystemExit(1)

# Final size (even height for H.264 yuv420p). Internal canvas is SS× for supersampling.
OUT_W, OUT_H = 720, 406
SS = 2
W, H = OUT_W * SS, OUT_H * SS
FRAMES = 40
FPS = 10

# Laksh / Claude-design tokens (sRGB)
BG = (8, 8, 8)
CREAM = (237, 232, 223)
ACCENT = (127, 176, 105)
SURFACE = (22, 22, 24)
CHROME = (18, 18, 20)


def sx(x: float | int) -> int:
    """Scale x from OUT_W logical layout to current render width."""
    return int(float(x) * W / OUT_W)


def sy(y: float | int) -> int:
    """Scale y from OUT_H logical layout to current render height."""
    return int(float(y) * H / OUT_H)


def smoothstep(t: float) -> float:
    t = max(0.0, min(1.0, t))
    return t * t * (3.0 - 2.0 * t)


def spring_overshoot(t: float) -> float:
    """0..1 → slight overshoot like Framer spring (bounded)."""
    t = max(0.0, min(1.0, t))
    s = 1.0 - math.pow(1.0 - t, 2.8)
    bump = 0.08 * math.sin(t * math.pi * 2.5) * (1.0 - t)
    return max(0.0, min(1.12, s + bump))


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def _font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for path in (
        "/System/Library/Fonts/Supplemental/SFMono-Regular.otf",
        "/System/Library/Fonts/SFNSMono.ttf",
        "/Library/Fonts/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    ):
        if os.path.isfile(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                pass
    return ImageFont.load_default()


def draw_radial_glow(base: Image.Image, cx: float, cy: float, phase: float) -> None:
    """Additive-ish green vignette pulse."""
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    dr = ImageDraw.Draw(overlay)
    pulse = 0.35 + 0.25 * math.sin(phase * math.pi * 2)
    rmax = int(max(W, H) * 0.55)
    for r in range(rmax, 0, -10 * SS):
        t = r / rmax
        alpha = int(28 * pulse * (1.0 - t) * (1.0 - t))
        if alpha < 2:
            continue
        bbox = (cx - r, cy - r, cx + r, cy + r)
        dr.ellipse(bbox, fill=(*ACCENT, alpha))
    blended = Image.alpha_composite(base.convert("RGBA"), overlay)
    base.paste(blended.convert("RGB"))


def draw_perspective_grid(img: Image.Image, phase: float) -> None:
    dr = ImageDraw.Draw(img)
    y0 = int(H * 0.58)
    cx = W * 0.5
    rows = 14
    for k in range(-rows, rows + 1):
        t = k / rows
        x1 = cx + t * W * 0.85
        x2 = cx + t * W * 0.22
        alpha = int(18 + 12 * math.sin(phase * 2 + k * 0.2))
        col = (alpha, alpha, min(40, alpha + 8))
        dr.line([(x1, H + sy(4)), (x2, y0)], fill=col, width=max(1, SS))


def draw_window_shadow(layer: Image.Image, box: tuple[int, int, int, int]) -> Image.Image:
    x0, y0, x1, y1 = box
    sh = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(sh)
    for i in range(18 * SS, 0, -2 * SS):
        a = int(35 - (i // SS) * 2)
        d.rounded_rectangle(
            (x0 - i + sx(8), y0 - i + sy(14), x1 + i - sx(8), y1 + i - sy(6)),
            radius=sx(22),
            fill=(0, 0, 0, max(0, a)),
        )
    sh = sh.filter(ImageFilter.GaussianBlur(10 * SS))
    return Image.alpha_composite(layer, sh)


def draw_rounded(
    dr: ImageDraw.ImageDraw,
    box: tuple[float, float, float, float],
    fill: tuple[int, int, int] | tuple[int, int, int, int],
    outline: tuple[int, int, int, int] | None = None,
    width: int = 1,
    radius: int = 12,
) -> None:
    dr.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def render_frame(
    i: int,
    particles: list[tuple[float, float, float, float]],
    font: ImageFont.ImageFont,
    font_small: ImageFont.ImageFont,
) -> Image.Image:
    phase = (i / FRAMES) * math.pi * 2
    u = i / FRAMES  # 0..~1

    img = Image.new("RGB", (W, H), BG)
    draw_radial_glow(img, W * 0.52, H * 0.42, u * 2)

    # Drifting particles (parallax)
    pr = ImageDraw.Draw(img)
    rr = max(1, SS)
    for j, (px, py, vx, vy) in enumerate(particles):
        px = (px + vx * 1.2) % (W + sx(20))
        py = (py + vy * 0.6) % (H + sy(20))
        particles[j] = (px, py, vx, vy)
        a = int(12 + 10 * math.sin(phase + j * 0.7))
        pr.ellipse((px - rr, py - rr, px + rr, py + rr), fill=(a + 20, a + 18, a + 16))

    draw_perspective_grid(img, u * 2 * math.pi)

    # Window float (subtle vertical bob)
    bob = int(sy(3) * math.sin(phase * 2))
    wx0, wy0 = sx(48), sy(36) + bob
    wx1, wy1 = W - sx(48), H - sy(42) + bob
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))

    layer = draw_window_shadow(layer, (wx0, wy0, wx1, wy1))

    d = ImageDraw.Draw(layer)
    draw_rounded(
        d,
        (wx0, wy0, wx1, wy1),
        (*CHROME, 245),
        outline=(*CREAM, 28),
        width=max(1, SS),
        radius=sx(20),
    )

    # Title bar
    d.rectangle((wx0, wy0, wx1, wy0 + sy(34)), fill=(14, 14, 16))
    d.text(
        (wx0 + sx(52), wy0 + sy(9)),
        "Laksh — mission control",
        fill=(*CREAM, 220),
        font=font_small,
        stroke_width=max(1, SS // 2),
        stroke_fill=CHROME,
    )
    # Traffic lights
    for k, col in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        cx = wx0 + sx(18) + k * sx(18)
        cy = wy0 + sy(17)
        tr = sx(5)
        d.ellipse((cx - tr, cy - tr, cx + tr, cy + tr), fill=(*col, 255))

    inner_y0 = wy0 + sy(34)
    sx0, sx1 = wx0 + sx(10), wx0 + sx(168)
    # Sidebar slide + spring width illusion
    slide = int(sy(18) * (1.0 - spring_overshoot((u * 3) % 1.0)))
    sx0 += slide // 4
    d.rounded_rectangle(
        (sx0, inner_y0 + sy(8), sx1, wy1 - sy(14)),
        radius=sx(14),
        fill=(*SURFACE, 230),
    )
    labels = ["Agents", "Shells", "Scan", "Perf"]
    for li, lab in enumerate(labels):
        yy = inner_y0 + sy(22) + li * sy(44)
        active = (i // 16 + li) % 4 == 0
        bx0, bx1 = sx0 + sx(10), sx1 - sx(10)
        fill = (32, 48, 36, 255) if active else (28, 28, 30, 240)
        d.rounded_rectangle((bx0, yy, bx1, yy + sy(34)), radius=sx(10), fill=fill)
        if active:
            glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            gd = ImageDraw.Draw(glow)
            for w in (6, 4, 2):
                ws = max(1, w * SS // 2)
                gd.rounded_rectangle(
                    (bx0 - ws, yy - ws, bx1 + ws, yy + sy(34) + ws),
                    radius=sx(12),
                    outline=(*ACCENT, 40 // max(1, w)),
                    width=max(1, SS // 2),
                )
            layer = Image.alpha_composite(layer, glow)
            d = ImageDraw.Draw(layer)
        d.text(
            (bx0 + sx(10), yy + sy(9)),
            lab,
            fill=(*CREAM, 200 if active else 120),
            font=font_small,
            stroke_width=max(1, SS // 2),
            stroke_fill=CHROME,
        )

    # Main board area
    mx0 = sx1 + sx(14)
    mx1 = wx1 - sx(14)
    my0 = inner_y0 + sy(8)
    my1 = wy1 - sy(120)

    # Moving pulse wave (green wash)
    wave = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    wd = ImageDraw.Draw(wave)
    wave_x = mx0 + (mx1 - mx0) * ((u * 1.3 + 0.1) % 1.0)
    wd.rounded_rectangle(
        (wave_x - sx(40), my0, wave_x + sx(40), my1),
        radius=sx(24),
        fill=(*ACCENT, 22),
    )
    wave = wave.filter(ImageFilter.GaussianBlur(16 * SS))
    layer = Image.alpha_composite(layer, wave)
    d = ImageDraw.Draw(layer)

    col_w = (mx1 - mx0) / 3
    titles = ("Idle", "Running", "Done")
    for ci in range(3):
        cx0 = mx0 + ci * col_w + sx(6)
        cx1 = mx0 + (ci + 1) * col_w - sx(6)
        d.rounded_rectangle(
            (cx0, my0, cx1, my0 + sy(26)),
            radius=sx(8),
            fill=(16, 16, 18, 255),
        )
        d.text(
            (cx0 + sx(10), my0 + sy(6)),
            titles[ci],
            fill=(*CREAM, 140),
            font=font_small,
            stroke_width=max(1, SS // 2),
            stroke_fill=(16, 16, 18),
        )

        # Cards with spring stagger
        for card_i in range(2):
            base_y = my0 + sy(36) + card_i * sy(56)
            delay = (ci * 0.12 + card_i * 0.08) % 1.0
            st = spring_overshoot(((u + delay) % 1.0))
            scale = lerp(0.88, 1.0, st)
            cy_off = int(lerp(sy(18), 0, st))
            ch = int(sy(42) * scale)
            y1 = base_y + cy_off
            y2 = y1 + ch
            glow_intensity = 0.0
            if ci == 1:
                glow_intensity = 0.35 + 0.25 * math.sin(phase * 2 + card_i)
            fill_rgb = (
                int(lerp(20, 32, glow_intensity)),
                int(lerp(22, 52, glow_intensity)),
                int(lerp(24, 36, glow_intensity)),
            )
            if glow_intensity > 0.2:
                gl = Image.new("RGBA", (W, H), (0, 0, 0, 0))
                gld = ImageDraw.Draw(gl)
                for w in (8, 5, 3):
                    ws = max(1, w * SS // 2)
                    gld.rounded_rectangle(
                        (cx0 + sx(6) - ws, y1 - ws, cx1 - sx(6) + ws, y2 + ws),
                        radius=sx(12),
                        outline=(*ACCENT, int(50 * glow_intensity / w)),
                        width=max(1, SS // 2),
                    )
                layer = Image.alpha_composite(layer, gl)
                d = ImageDraw.Draw(layer)
            draw_rounded(
                d,
                (cx0 + sx(8), y1, cx1 - sx(8), y2),
                (*fill_rgb, 250),
                outline=(*CREAM, 22 if ci == 1 else 14),
                width=max(1, SS),
                radius=sx(12),
            )
            # Fake shimmer line
            sh_y = y1 + sy(8) + int(sy(6) * math.sin(phase * 3 + ci))
            d.line(
                (cx0 + sx(16), sh_y, cx1 - sx(16), sh_y),
                fill=(*CREAM, 35),
                width=max(1, SS),
            )

    # Terminal strip (typewriter)
    ty0 = wy1 - sy(98)
    d.rounded_rectangle(
        (mx0, ty0, mx1, wy1 - sy(14)),
        radius=sx(12),
        fill=(10, 10, 12, 250),
    )
    cmd = "swift build  # agents · shells · scan"
    reveal = int(len(cmd) * smoothstep((u * 2.2) % 1.0))
    cursor_on = (i // 6) % 2 == 0
    line = "~ " + cmd[:reveal] + ("█" if cursor_on else " ")
    d.text(
        (mx0 + sx(14), ty0 + sy(14)),
        line,
        fill=(*ACCENT, 255),
        font=font,
        stroke_width=max(2, SS),
        stroke_fill=(0, 0, 0),
    )
    d.text(
        (mx0 + sx(14), ty0 + sy(38)),
        "local-first · SwiftTerm PTY",
        fill=(*CREAM, 90),
        font=font,
        stroke_width=max(1, SS // 2),
        stroke_fill=(10, 10, 12),
    )

    out = Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")
    return out


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    media_dir = os.path.join(root, "website", "media")
    out_gif = os.path.join(media_dir, "laksh-promo.gif")
    out_mp4 = os.path.join(media_dir, "laksh-promo.mp4")
    out_poster = os.path.join(media_dir, "laksh-promo-poster.png")
    os.makedirs(media_dir, exist_ok=True)

    random.seed(42)
    particles: list[tuple[float, float, float, float]] = []
    for _ in range(36):
        particles.append(
            (
                random.uniform(0, W),
                random.uniform(0, H),
                random.uniform(-0.35, 0.35),
                random.uniform(-0.2, 0.2),
            )
        )

    font = _font(13 * SS)
    font_small = _font(11 * SS)

    tmp = tempfile.mkdtemp(prefix="laksh-promo-")
    try:
        for i in range(FRAMES):
            im = render_frame(i, particles, font, font_small)
            im = im.resize((OUT_W, OUT_H), Image.Resampling.LANCZOS)
            im.save(os.path.join(tmp, f"f{i:03d}.png"), compress_level=3)

        pattern = os.path.join(tmp, "f%03d.png")
        gif_fc = (
            "[0:v]split[s0][s1];"
            "[s0]palettegen=max_colors=256:reserve_transparent=0:stats_mode=full[p];"
            "[s1][p]paletteuse=dither=floyd_steinberg:diff_mode=rectangle:new=1"
        )
        subprocess.run(
            [
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
                gif_fc,
                "-loop",
                "0",
                out_gif,
            ],
            check=True,
            cwd=tmp,
        )

        poster_path = os.path.join(tmp, "f000.png")
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-hide_banner",
                "-loglevel",
                "error",
                "-i",
                poster_path,
                "-frames:v",
                "1",
                out_poster,
            ],
            check=True,
        )

        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-hide_banner",
                "-loglevel",
                "error",
                "-framerate",
                str(FPS),
                "-i",
                pattern,
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-crf",
                "18",
                "-preset",
                "slow",
                "-movflags",
                "+faststart",
                out_mp4,
            ],
            check=True,
            cwd=tmp,
        )
    finally:
        for name in os.listdir(tmp):
            os.unlink(os.path.join(tmp, name))
        os.rmdir(tmp)

    print(out_gif, out_mp4, sep="\n", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
