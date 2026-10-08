import io, math, sys
import numpy as np, resvg_py
from PIL import Image
sys.path.insert(0, ".")
from iconbase import HEAD, TAIL, TRACE, path

# 減衰振動 x(t) = A e^{-t/τ} sin(2π f t)  (共振体のインパルス応答) → テキストカーソル
t = np.linspace(0, 1, 1600)
tau, cyc, A = 0.30, 4.0, 185
X0, X1 = 220, 714
wave_y = 512 - A * np.exp(-t / tau) * np.sin(2 * math.pi * cyc * t)
caret = '<rect x="768" y="340" width="36" height="344" rx="18" fill="%s" filter="url(#glow)"/>' % TRACE
app_svg = HEAD + f'<path d="{path(X0 + (X1 - X0) * t, wave_y)}" fill="none" stroke="{TRACE}" stroke-width="20" ' \
    'stroke-linecap="round" stroke-linejoin="round" filter="url(#glow)"/>' + caret + TAIL
open("final.svg", "w").write(app_svg)

# メニューバー用のテンプレート画像 (黒の図形 + 透明、18pt → 36px@2x)。波は 2.5 周期に簡略化して太く
tt = np.linspace(0, 1, 400)
mx = 2.5 + 23 * tt
my = 18 - 12 * np.exp(-tt / 0.35) * np.sin(2 * math.pi * 2.5 * tt)
menubar_svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36">
<path d="{path(mx, my)}" fill="none" stroke="#000" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"/>
<rect x="29.5" y="5" width="4" height="26" rx="2" fill="#000"/></svg>'''
open("menubar.svg", "w").write(menubar_svg)

def render(svg, w, h=None):
    png = resvg_py.svg_to_bytes(svg_string=svg, width=w, height=h or w)
    return Image.open(io.BytesIO(bytes(png))).convert("RGBA")

big = render(app_svg, 1024); big.save("final_1024.png")
for s in (18, 36):
    render(menubar_svg, s).save(f"menubar_{s}.png")
# preview: icon sizes + menubar glyph on light & dark bars
W, H = 1500, 560
sheet = Image.new("RGBA", (W, H), (236, 236, 238, 255))
sheet.alpha_composite(big.resize((460, 460), Image.LANCZOS), (30, 40))
x = 540
for s in (256, 128, 64, 32, 16):
    sheet.alpha_composite(big.resize((s, s), Image.LANCZOS), (x, 40 + (256 - s) // 2)); x += s + 30
for i, (bg, inv) in enumerate((((246, 246, 246), False), ((40, 40, 44), True))):
    bar = Image.new("RGBA", (420, 60), bg + (255,))
    for j, s in enumerate((18, 36)):
        g = render(menubar_svg, s)
        if inv:
            r, gg, b, a = g.split(); g = Image.merge("RGBA", (a.point(lambda v: 255), a.point(lambda v: 255), a.point(lambda v: 255), a))
        bar.alpha_composite(g, (30 + j * 120, (60 - s) // 2))
    red = render(menubar_svg, 18); r, gg, b, a = red.split(); red = Image.merge("RGBA", (a.point(lambda v: 255), a.point(lambda v: 59), a.point(lambda v: 48), a))
    bar.alpha_composite(red, (300, 21))
    sheet.alpha_composite(bar, (540, 340 + i * 90))
sheet.save("final_preview.png")
print("ok")
