#!/usr/bin/env python3
"""評価用テストセットを macOS の say で合成する。refs.json に正解文(句読点付き)を保存。"""
import json
import os

from ttsutil import HERE, check_voices, environment, synth
SENTENCES = [
    "明日の会議は午後三時からに変更になりました。",
    "資料を確認して、修正点があれば連絡してください。",
    "来週の金曜日までに見積もりを送ります。",
    "今日はありがとうございました。引き続きよろしくお願いいたします。",
    "新しいプロジェクトの予算について、クライアントと相談する必要があります。",
    "了解です。",
    "少し遅れます、すみません。",
    "企画書のキービジュアルは、もう少し明るいトーンにしたいです。",
    "プレゼンの構成案をスラックで共有しました。",
    "PDFで送ってもらえますか？",
    "撮影のスケジュールは、十月の第二週で調整しています。",
    "先方の担当者が変わったので、改めてご挨拶に伺います。",
    "その件については、社内で確認してから折り返しご連絡します。",
    "ロゴの位置を右上に移動して、サイズを少し小さくしてください。",
    "予算は五百万円で、納期は年内を想定しています。",
    "なるほど、それはいいアイデアですね。",
    "動画の尺は十五秒と三十秒の二パターンを用意してください。",
    "ターゲットは二十代から三十代の女性です。",
    "修正版をアップしたので、お手すきの際にご確認ください。",
    "え、それって本当ですか？",
    "議事録は私のほうでまとめておきます。",
    "競合他社の事例をいくつか調べて、比較表を作ってください。",
    "来月からリモートワークが週三日になります。",
    "ブランドのトーンアンドマナーに合わせて、コピーを三案ほど考えてみました。",
]
VOICES = ["Kyoko", "Eddy (日本語（日本）)", "Flo (日本語（日本）)"]
check_voices(VOICES)
os.chdir(HERE)
refs = []
for vi, v in enumerate(VOICES):
    for si, s in enumerate(SENTENCES):
        name = f"wav/v{vi}_s{si:02d}.wav"
        refs.append({"file": name, "voice": v, "text": s, "sha256": synth(s, v, name)})
json.dump(refs, open("refs.json", "w"), ensure_ascii=False, indent=1)
json.dump({"macos": environment(), "voices": VOICES}, open("refs.json".replace(".json", ".meta.json"), "w"), indent=1)
print(len(refs), "clips")
