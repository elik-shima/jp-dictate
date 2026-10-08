#!/usr/bin/env python3
"""アイコン一式を作る: AppIcon.icns (アプリ) と MenubarTemplate(.png/@2x.png) (メニューバー)。
   依存: resvg_py, pillow, numpy (例: uv pip install resvg-py pillow numpy)。
   デザイン: 減衰振動 (共振体のインパルス応答 e^{-t/τ} sin 2πft) がテキストカーソルに変わる。"""
import io, os, shutil, subprocess, tempfile
import resvg_py
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)
import final  # noqa: E402  (final.svg / menubar.svg を書き出す)

def render(svg, size):
    return Image.open(io.BytesIO(bytes(resvg_py.svg_to_bytes(svg_string=svg, width=size, height=size))))

app_svg, bar_svg = open("final.svg").read(), open("menubar.svg").read()
with tempfile.TemporaryDirectory() as d:
    iconset = os.path.join(d, "AppIcon.iconset")
    os.makedirs(iconset)
    for s in (16, 32, 128, 256, 512):
        render(app_svg, s).save(f"{iconset}/icon_{s}x{s}.png")
        render(app_svg, s * 2).save(f"{iconset}/icon_{s}x{s}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", "../AppIcon.icns"], check=True)
render(bar_svg, 18).save("../MenubarTemplate.png")
render(bar_svg, 36).save("../MenubarTemplate@2x.png")
for f in ("final_1024.png", "final_preview.png", "menubar_18.png", "menubar_36.png"):
    if os.path.exists(f):
        os.remove(f)
print("wrote app/AppIcon.icns, app/MenubarTemplate.png, app/MenubarTemplate@2x.png")
