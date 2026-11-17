"""Draws the app's mark and writes the icon's sources:

    python3 scripts/icon/generate.py

- OhMyCode/AppIcon.icon/Assets/Mark.svg: the mark alone, on nothing (the Icon Composer icon
  macOS 26 and later show, over the icon's own near-black fill).
- scripts/icon/Logo.svg: the mark on its rounded square (the logo in the app, and the icon for
  earlier macOS; scripts/icon/render.sh turns it into PNGs).

The mark is in the ZeroVoid Lab mark's language (zerovoidlab.dev): a hexagon on near-black and a
lime orbit passing behind the glyph, then in front of it. The glyph is code's own, </>, its ends
cut level as the lab's letters are. Everything is plain stroked and filled paths (no masks or
clips), so any SVG renderer draws it the same.
"""
import math
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
WHITE, LIME = "#F5F5F5", "#C5FF4A"
CY = 262  # the orbit's center (the mark is drawn in a 512 square)


def poly(points):
    return "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in points) + " Z"


def scaled(points, s, cx=256, cy=CY):
    return [(cx + (x - cx) * s, cy + (y - cy) * s) for x, y in points]


# "<" and ">": arms ending in level cuts, sized to sit inside the orbit.
top, bottom, cut, end, tip = 206, 318, 42, 214, 118
less = scaled([(end - cut, top), (end, top), (tip + cut, CY), (end, bottom), (end - cut, bottom), (tip, CY)], 0.78)
greater = [(512 - x, y) for x, y in less]
# "/": long enough to pass through the orbit, behind it at the top and in front at the bottom.
slash_top, slash_bottom, slash_width, lean = 142, 398, 36, 0.30
def slash_left(y): return 236 + lean * (CY - y)
slash = [(slash_left(slash_top), slash_top), (slash_left(slash_top) + slash_width, slash_top),
         (slash_left(slash_bottom) + slash_width, slash_bottom), (slash_left(slash_bottom), slash_bottom)]

# The orbit: an ellipse turned 24° back. Its far half (above the center line, in its own frame)
# passes behind the glyph, so it breaks where it would cross the slash, leaving a gap; its near
# half passes in front.
RX, RY, ANGLE, ORBIT_WIDTH, GAP = 222, 90, math.radians(-24), 18, 18


def orbit_point(t):
    x, y = RX * math.cos(t), RY * math.sin(t)
    return (256 + x * math.cos(ANGLE) - y * math.sin(ANGLE), CY + x * math.sin(ANGLE) + y * math.cos(ANGLE))


def distance_to_polygon(p, points):
    def inside():
        hit = False
        for (x1, y1), (x2, y2) in zip(points, points[1:] + points[:1]):
            if (y1 > p[1]) != (y2 > p[1]) and p[0] < x1 + (p[1] - y1) * (x2 - x1) / (y2 - y1):
                hit = not hit
        return hit
    if inside():
        return 0
    best = math.inf
    for (x1, y1), (x2, y2) in zip(points, points[1:] + points[:1]):
        dx, dy = x2 - x1, y2 - y1
        u = max(0, min(1, ((p[0] - x1) * dx + (p[1] - y1) * dy) / (dx * dx + dy * dy)))
        best = min(best, math.hypot(p[0] - x1 - u * dx, p[1] - y1 - u * dy))
    return best


def runs(start, stop, keep, steps=720):
    """The orbit's arcs from angle start to stop where keep(point) holds, as elliptical arc
    commands (polylines show seams where their segments meet)."""
    spans, begin = [], None
    for i in range(steps + 1):
        t = start + (stop - start) * i / steps
        if keep(orbit_point(t)):
            begin = t if begin is None else begin
            end = t
        elif begin is not None:
            spans.append((begin, end))
            begin = None
    if begin is not None:
        spans.append((begin, end))
    paths = []
    for a, b in spans:
        pieces = max(1, math.ceil((b - a) / (math.pi / 2)))
        d = "M%.2f %.2f" % orbit_point(a)
        for i in range(1, pieces + 1):
            d += " A%g %g %g 0 1 %.2f %.2f" % ((RX, RY, math.degrees(ANGLE)) + orbit_point(a + (b - a) * i / pieces))
        paths.append(d)
    return paths


far = runs(math.pi, 2 * math.pi, lambda p: distance_to_polygon(p, slash) > GAP)
# A little past the far half's ends, so the halves overlap with no seam.
near = runs(-0.02, math.pi + 0.02, lambda p: True)

hexagon = "M256 66 L420.5 161 V351 L256 446 L91.5 351 V161 Z"


def mark(transform):
    orbit = lambda d: f'<path d="{d}" fill="none" stroke="{LIME}" stroke-width="{ORBIT_WIDTH}" stroke-linecap="butt" stroke-linejoin="round"/>'
    return "\n".join([
        f'<g transform="{transform}">',
        f'  <path d="{hexagon}" fill="none" stroke="{WHITE}" stroke-width="22" stroke-linejoin="round"/>',
        *("  " + orbit(d) for d in far),
        f'  <path d="{poly(less)} {poly(greater)} {poly(slash)}" fill="{WHITE}"/>',
        *("  " + orbit(d) for d in near),
        "</g>",
    ])


def write(path, body):
    with open(os.path.join(ROOT, path), "w") as f:
        f.write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">\n'
                "<!-- Written by scripts/icon/generate.py: change it there. -->\n" + body + "\n</svg>\n")


# Icon Composer: the mark at the size of the icon's artwork (the system adds the shape and fill).
os.makedirs(os.path.join(ROOT, "OhMyCode/AppIcon.icon/Assets"), exist_ok=True)
write("OhMyCode/AppIcon.icon/Assets/Mark.svg", mark("translate(512 512) scale(1.62) translate(-256 -256)"))
# The logo: the macOS icon grid, an 824-point rounded square in the middle of 1024.
write("scripts/icon/Logo.svg", "\n".join([
    '<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
    '<stop offset="0" stop-color="#161616"/><stop offset="1" stop-color="#050505"/></linearGradient></defs>',
    '<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>',
    '<rect x="101.5" y="101.5" width="821" height="821" rx="183.5" fill="none" stroke="#F5F5F5" stroke-opacity="0.1" stroke-width="3"/>',
    mark("translate(512 512) scale(1.4) translate(-256 -256)"),
]))
