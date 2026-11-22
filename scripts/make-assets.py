"""Regenerates the app icon / splash PNGs in assets/ and public/icons/ (requires Pillow).

Look: deep charcoal tile, bold snow-white "M". The same M is also written as a single-colour layer
(assets/icon-monochrome.png) so Android 13+ "themed icons" tint it like every other app on the home screen.
"""
from PIL import Image, ImageDraw
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHARCOAL = (18, 20, 22)
SNOW = (245, 247, 249)
SS = 4  # supersampling: PIL lines are not anti-aliased, so everything is drawn 4x and scaled down

def m_points(cx, cy, w, h):
    l, r, t, b = cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
    return [(l, b), (l, t), (cx, t + h * 0.58), (r, t), (r, b)]

def mark(size, bg, scale, color):
    # geometry is given for a 1024 canvas and scaled
    k = size / 1024 * scale
    n = size
    img = Image.new("RGBA", (n * SS, n * SS), (0, 0, 0, 0) if bg is None else bg + (255,))
    d = ImageDraw.Draw(img)
    w, h, st = 380 * k, 340 * k, 100 * k
    cx, cy = n / 2, n / 2 + 6 * k
    pts = [(x * SS, y * SS) for x, y in m_points(cx, cy, w, h)]
    s = st * SS
    d.line(pts, fill=color + (255,), width=int(s), joint="curve")
    for p in (pts[0], pts[-1], pts[1], pts[-2]):
        d.ellipse([p[0] - s / 2, p[1] - s / 2, p[0] + s / 2, p[1] + s / 2], fill=color + (255,))
    return img.resize((n, n), Image.LANCZOS)

def save(img, *parts):
    path = os.path.join(ROOT, *parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)

S = 1024
# Full icon (legacy launchers, PWA)
full = mark(S, CHARCOAL, 1.18, SNOW).convert("RGB")
save(full, "assets", "icon-only.png")
for size in (512, 192):
    save(full.resize((size, size), Image.LANCZOS), "public", "icons", f"icon-{size}.png")

# Adaptive icon layers (the M stays inside the 66 % safe zone of any launcher mask)
save(mark(S, None, 1.0, SNOW), "assets", "icon-foreground.png")
save(Image.new("RGB", (S, S), CHARCOAL), "assets", "icon-background.png")
# Themed-icon layer: only the alpha matters, Android colours it
save(mark(S, None, 1.0, (255, 255, 255)), "assets", "icon-monochrome.png")

# Splash screens
for name, bg, fg in (("splash.png", SNOW, CHARCOAL), ("splash-dark.png", (14, 15, 16), SNOW)):
    sp = mark(2732, bg, 1.0 * 0.62, fg).convert("RGB")
    save(sp, "assets", name)
print("assets written")
