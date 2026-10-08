import io, math
import numpy as np, resvg_py
from PIL import Image, ImageDraw, ImageFont

TRACE = "#48f0c8"   # phosphor-like teal
def squircle(size=824, off=100, n=5.0):
    # superellipse approximating Apple's continuous-corner icon shape
    pts = []
    a = size / 2; c = off + a
    for t in np.linspace(0, 2 * math.pi, 720, endpoint=False):
        ct, st = math.cos(t), math.sin(t)
        x = c + a * math.copysign(abs(ct) ** (2 / n), ct)
        y = c + a * math.copysign(abs(st) ** (2 / n), st)
        pts.append(f"{x:.2f},{y:.2f}")
    return "M" + " L".join(pts) + " Z"

def path(xs, ys):
    return "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in zip(xs, ys))

HEAD = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
 <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1c2226"/><stop offset="1" stop-color="#0a0d0f"/></linearGradient>
 <radialGradient id="sheen" cx="0.5" cy="0.35" r="0.7"><stop offset="0" stop-color="#ffffff" stop-opacity="0.07"/><stop offset="1" stop-color="#ffffff" stop-opacity="0"/></radialGradient>
 <filter id="glow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="10" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
 <clipPath id="clip"><path d="{squircle()}"/></clipPath>
</defs>
<path d="{squircle()}" fill="url(#bg)"/>
<g clip-path="url(#clip)">'''
TAIL = f'''<path d="{squircle()}" fill="url(#sheen)"/></g>
<path d="{squircle()}" fill="none" stroke="#ffffff" stroke-opacity="0.10" stroke-width="3"/>
</svg>'''

def graticule(x0, y0, w, h, nx, ny, op=0.10, ticks=True):
    g = []
    for i in range(nx + 1):
        x = x0 + w * i / nx
        g.append(f'<line x1="{x:.1f}" y1="{y0}" x2="{x:.1f}" y2="{y0+h}" stroke="#fff" stroke-opacity="{op}" stroke-width="2"/>')
    for j in range(ny + 1):
        y = y0 + h * j / ny
        g.append(f'<line x1="{x0}" y1="{y:.1f}" x2="{x0+w}" y2="{y:.1f}" stroke="#fff" stroke-opacity="{op}" stroke-width="2"/>')
    if ticks:  # 5 minor ticks per division on the centre axes (real scope convention)
        cx, cy = x0 + w / 2, y0 + h / 2
        for k in range(nx * 5 + 1):
            x = x0 + w * k / (nx * 5)
            g.append(f'<line x1="{x:.1f}" y1="{cy-7}" x2="{x:.1f}" y2="{cy+7}" stroke="#fff" stroke-opacity="{op*1.8}" stroke-width="2"/>')
        for k in range(ny * 5 + 1):
            y = y0 + h * k / (ny * 5)
            g.append(f'<line x1="{cx-7}" y1="{y:.1f}" x2="{cx+7}" y2="{y:.1f}" stroke="#fff" stroke-opacity="{op*1.8}" stroke-width="2"/>')
    return "\n".join(g)

def trace(d, w=18):
    return f'<path d="{d}" fill="none" stroke="{TRACE}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round" filter="url(#glow)"/>'

