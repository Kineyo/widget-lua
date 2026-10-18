#!/usr/bin/env python3
"""
generate_sprites.py - Generates circular state sprites and geometric UI icons
from qwen_image-v2.jpeg for the hybrid Lua + C/C++ Qwen Widget.
Zero emojis, clean vector geometry, stripped EXIF metadata.
"""

import math
import os
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_IMAGE = os.path.join(BASE_DIR, "qwen_image-v2.jpeg")
ASSETS_DIR = os.path.join(BASE_DIR, "assets")
SPRITES_DIR = os.path.join(ASSETS_DIR, "sprites")
ICONS_DIR = os.path.join(ASSETS_DIR, "icons")


def ensure_dirs():
    os.makedirs(SPRITES_DIR, exist_ok=True)
    os.makedirs(ICONS_DIR, exist_ok=True)


def create_clean_avatar(src_img):
    """Creates sanitized avatar.jpg, avatar.png, and icon.png without EXIF."""
    w, h = src_img.size
    # Crop focused on character's face, glasses, hairclip, and headphones
    crop_box = (int(w * 0.11), int(h * 0.04), int(w * 0.89), int(h * 0.82))
    cropped = src_img.crop(crop_box).resize((512, 512), Image.Resampling.LANCZOS)

    # Save clean JPEG without EXIF
    clean_rgb = cropped.convert("RGB")
    clean_rgb.save(os.path.join(ASSETS_DIR, "avatar.jpg"), "JPEG", quality=94, exif=b"")
    clean_rgb.save(os.path.join(ASSETS_DIR, "avatar.png"), "PNG", optimize=True)

    # Create 256x256 circular icon.png
    icon_sz = 256
    icon_img = make_circular_sprite(cropped, icon_sz, (124, 58, 237), "idle", badge=False)
    icon_img.save(os.path.join(ASSETS_DIR, "icon.png"), "PNG", optimize=True)
    return cropped


def draw_badge_symbol(draw, state, bx, by, br):
    """Draws clean geometric vector symbols inside the status badge (zero emojis)."""
    fg = (248, 250, 252, 255)
    if state == "chatting":
        # Geometric speech rectangle with tail
        draw.rounded_rectangle([bx - 10, by - 8, bx + 10, by + 5], radius=4, outline=fg, width=2)
        draw.polygon([(bx - 4, by + 5), (bx - 8, by + 11), (bx + 2, by + 5)], fill=fg)
        draw.ellipse([bx - 5, by - 3, bx - 3, by - 1], fill=fg)
        draw.ellipse([bx - 1, by - 3, bx + 1, by - 1], fill=fg)
        draw.ellipse([bx + 3, by - 3, bx + 5, by - 1], fill=fg)
    elif state == "thinking":
        # Geometric neural nodes / pulse
        pts = [(bx - 9, by), (bx - 4, by - 8), (bx + 4, by + 8), (bx + 9, by)]
        draw.line(pts, fill=fg, width=2)
        for px, py in pts:
            draw.ellipse([px - 2.5, py - 2.5, px + 2.5, py + 2.5], fill=fg)
    elif state == "music":
        # Geometric equalizer bars
        bars = [(-7, 5), (-2, 10), (3, 7), (8, 4)]
        for dx, bh in bars:
            draw.rounded_rectangle([bx + dx - 1.5, by - bh, bx + dx + 1.5, by + bh], radius=1, fill=fg)
    elif state == "grammar":
        # Geometric fountain pen / editnib
        draw.polygon([(bx - 7, by + 7), (bx - 3, by + 7), (bx + 8, by - 4), (bx + 4, by - 8), (bx - 7, by + 3)], outline=fg, width=2)
        draw.line([(bx - 8, by + 9), (bx + 8, by + 9)], fill=fg, width=2)
    elif state == "error":
        # Geometric exclamation bar
        draw.rounded_rectangle([bx - 2, by - 9, bx + 2, by + 2], radius=1, fill=fg)
        draw.ellipse([bx - 2.5, by + 5, bx + 2.5, by + 10], fill=fg)
    elif state == "hover":
        # Geometric four-point star / diamond
        draw.polygon([(bx, by - 9), (bx + 3, by - 3), (bx + 9, by), (bx + 3, by + 3),
                      (bx, by + 9), (bx - 3, by + 3), (bx - 9, by), (bx - 3, by - 3)], fill=fg)


def make_circular_sprite(base_crop, size, ring_rgb, state, badge=True):
    """Composes a high-DPI supersampled circular sprite with state styling."""
    ss = size * 2  # 2x supersampling for crisp anti-aliased edges
    canvas = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    pad = 16
    inner_d = ss - pad * 2

    img = base_crop.resize((inner_d, inner_d), Image.Resampling.LANCZOS).convert("RGBA")

    # Replace near-white background pixels smoothly with dark obsidian gradient BEFORE overlays
    px = img.load()
    for y in range(inner_d):
        t = y / float(inner_d)
        bg_r = int(16 + 10 * (1.0 - t))
        bg_g = int(14 + 8 * (1.0 - t))
        bg_b = int(28 + 18 * (1.0 - t))
        for x in range(inner_d):
            r, g, b, a = px[x, y]
            lum = (r + g + b) / 3.0
            sat = max(r, g, b) - min(r, g, b)
            # Exclude skin/glasses/hairclip inside face bounding circle
            in_face = (inner_d * 0.24 < x < inner_d * 0.70 and inner_d * 0.18 < y < inner_d * 0.62)
            if not in_face and lum > 235 and sat < 22:
                tr = int(bg_r * 0.88 + ring_rgb[0] * 0.12)
                tg = int(bg_g * 0.88 + ring_rgb[1] * 0.12)
                tb = int(bg_b * 0.88 + ring_rgb[2] * 0.12)
                px[x, y] = (tr, tg, tb, 255)
            elif not in_face and lum > 210 and sat < 24:
                alpha_f = (lum - 210.0) / 25.0
                tr = int(bg_r * 0.88 + ring_rgb[0] * 0.12)
                tg = int(bg_g * 0.88 + ring_rgb[1] * 0.12)
                tb = int(bg_b * 0.88 + ring_rgb[2] * 0.12)
                nr = int(r * (1.0 - alpha_f) + tr * alpha_f)
                ng = int(g * (1.0 - alpha_f) + tg * alpha_f)
                nb = int(b * (1.0 - alpha_f) + tb * alpha_f)
                px[x, y] = (nr, ng, nb, 255)

    # State-specific color grading on character image
    if state == "hover":
        img = ImageEnhance.Brightness(img).enhance(1.07)
        img = ImageEnhance.Contrast(img).enhance(1.05)
    elif state == "thinking":
        img = ImageEnhance.Color(img).enhance(1.12)
    elif state == "error":
        overlay = Image.new("RGBA", (inner_d, inner_d), (239, 68, 68, 24))
        img = Image.alpha_composite(img, overlay)
    elif state == "grammar":
        overlay = Image.new("RGBA", (inner_d, inner_d), (16, 185, 129, 18))
        img = Image.alpha_composite(img, overlay)
    elif state == "music":
        overlay = Image.new("RGBA", (inner_d, inner_d), (236, 72, 153, 20))
        img = Image.alpha_composite(img, overlay)

    # Circular mask
    mask = Image.new("L", (inner_d, inner_d), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.ellipse([0, 0, inner_d - 1, inner_d - 1], fill=255)

    # Outer glow halo
    glow_layer = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(glow_layer)
    glow_alpha = 95 if state != "idle" else 50
    gdraw.ellipse([pad - 6, pad - 6, ss - pad + 6, ss - pad + 6],
                  outline=(ring_rgb[0], ring_rgb[1], ring_rgb[2], glow_alpha), width=10)
    glow_layer = glow_layer.filter(ImageFilter.GaussianBlur(radius=6))
    canvas = Image.alpha_composite(canvas, glow_layer)

    # Paste masked avatar
    canvas.paste(img, (pad, pad), mask)
    draw = ImageDraw.Draw(canvas)

    # Crisp double ring border
    ring_w = 6 if state != "idle" else 4
    draw.ellipse([pad, pad, ss - pad - 1, ss - pad - 1],
                 outline=(ring_rgb[0], ring_rgb[1], ring_rgb[2], 235), width=ring_w)
    draw.ellipse([pad + ring_w, pad + ring_w, ss - pad - 1 - ring_w, ss - pad - 1 - ring_w],
                 outline=(255, 255, 255, 45), width=2)

    # Optional state badge on bottom-right
    if badge and state != "idle":
        br = 24
        bx = ss - pad - br + 4
        by = ss - pad - br + 4
        draw.ellipse([bx - br, by - br, bx + br, by + br],
                     fill=(15, 13, 26, 245),
                     outline=(ring_rgb[0], ring_rgb[1], ring_rgb[2], 255), width=4)
        draw_badge_symbol(draw, state, bx, by, br)

    return canvas.resize((size, size), Image.Resampling.LANCZOS)


def generate_ui_icons():
    """Generates clean geometric vector icons in assets/icons/ (48x48 PNG)."""
    sz = 48
    fg = (248, 250, 252, 255)
    accent = (139, 92, 246, 255)

    icons = [
        "play", "pause", "next", "prev", "volume", "mute",
        "chat", "settings", "music", "grammar", "close", "pin", "cloud", "cpu"
    ]

    for name in icons:
        im = Image.new("RGBA", (sz, sz), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        if name == "play":
            d.polygon([(14, 10), (14, 38), (38, 24)], fill=fg)
        elif name == "pause":
            d.rounded_rectangle([13, 10, 21, 38], radius=2, fill=fg)
            d.rounded_rectangle([27, 10, 35, 38], radius=2, fill=fg)
        elif name == "next":
            d.polygon([(11, 11), (11, 37), (29, 24)], fill=fg)
            d.rounded_rectangle([32, 11, 36, 37], radius=1, fill=fg)
        elif name == "prev":
            d.rounded_rectangle([12, 11, 16, 37], radius=1, fill=fg)
            d.polygon([(37, 11), (37, 37), (19, 24)], fill=fg)
        elif name == "volume":
            d.polygon([(10, 18), (18, 18), (26, 11), (26, 37), (18, 30), (10, 30)], fill=fg)
            d.arc([22, 14, 36, 34], start=-60, end=60, fill=fg, width=3)
        elif name == "mute":
            d.polygon([(10, 18), (18, 18), (26, 11), (26, 37), (18, 30), (10, 30)], fill=fg)
            d.line([(30, 18), (40, 30)], fill=(239, 68, 68, 255), width=3)
            d.line([(40, 18), (30, 30)], fill=(239, 68, 68, 255), width=3)
        elif name == "chat":
            d.rounded_rectangle([8, 10, 40, 32], radius=6, outline=fg, width=3)
            d.polygon([(16, 32), (12, 40), (24, 32)], fill=fg)
        elif name == "settings":
            d.ellipse([15, 15, 33, 33], outline=fg, width=3)
            d.ellipse([21, 21, 27, 27], fill=accent)
            for a in range(0, 360, 45):
                rad = math.radians(a)
                x1 = 24 + int(10 * math.cos(rad))
                y1 = 24 + int(10 * math.sin(rad))
                x2 = 24 + int(15 * math.cos(rad))
                y2 = 24 + int(15 * math.sin(rad))
                d.line([(x1, y1), (x2, y2)], fill=fg, width=3)
        elif name == "music":
            for i, bh in enumerate([10, 16, 12, 8]):
                x = 12 + i * 8
                d.rounded_rectangle([x - 2, 24 - bh, x + 2, 24 + bh], radius=2, fill=fg)
        elif name == "grammar":
            d.polygon([(12, 36), (18, 36), (36, 18), (30, 12), (12, 30)], outline=fg, width=3)
            d.line([(10, 40), (38, 40)], fill=accent, width=3)
        elif name == "close":
            d.line([(13, 13), (35, 35)], fill=fg, width=3)
            d.line([(35, 13), (13, 35)], fill=fg, width=3)
        elif name == "pin":
            d.rounded_rectangle([16, 10, 32, 26], radius=4, outline=fg, width=3)
            d.line([(24, 26), (24, 40)], fill=accent, width=3)
        elif name == "cloud":
            d.rounded_rectangle([10, 20, 38, 34], radius=7, outline=fg, width=3)
            d.arc([16, 12, 32, 28], start=180, end=360, fill=fg, width=3)
        elif name == "cpu":
            d.rounded_rectangle([14, 14, 34, 34], radius=3, outline=fg, width=3)
            d.rectangle([20, 20, 28, 28], fill=accent)

        im.save(os.path.join(ICONS_DIR, f"{name}.png"), "PNG", optimize=True)


def main():
    ensure_dirs()
    if not os.path.exists(SRC_IMAGE):
        raise FileNotFoundError(f"Source image not found: {SRC_IMAGE}")

    src_img = Image.open(SRC_IMAGE)
    base_crop = create_clean_avatar(src_img)

    states = {
        "idle":     (139, 92, 246),   # Violet
        "hover":    (167, 139, 250),  # Bright Lavender
        "chatting": (6, 182, 212),    # Cyan
        "thinking": (245, 158, 11),   # Amber
        "music":    (236, 72, 153),   # Pink/Magenta
        "grammar":  (16, 185, 129),   # Emerald
        "error":    (239, 68, 68),    # Red/Coral
    }

    for state, rgb in states.items():
        sprite = make_circular_sprite(base_crop, 160, rgb, state, badge=(state != "idle"))
        png_path = os.path.join(SPRITES_DIR, f"{state}.png")
        webp_path = os.path.join(SPRITES_DIR, f"{state}.webp")
        sprite.save(png_path, "PNG", optimize=True)
        sprite.save(webp_path, "WEBP", quality=92)
        print(f"[OK] Generated sprite: {state} (.png & .webp)")

    generate_ui_icons()
    print("[OK] Generated geometric UI icons in assets/icons/")


if __name__ == "__main__":
    main()
