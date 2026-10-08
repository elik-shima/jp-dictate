#!/usr/bin/env python3
"""チューニング用の開発セット(評価セットとは別の文)。候補の調整にはこちらだけを使う。"""
import json
import os

from ttsutil import HERE, check_voices, environment, synth
SENTENCES = [
    "打ち合わせの場所は、渋谷のオフィスに変更になりました。",
    "この案で進めて問題ないか、部長に確認してみます。",
    "納品データは、明後日の正午までにアップロードします。",
    "お疲れさまです。本日の進捗を共有します。",
    "インスタグラム用の画像を三枚追加でお願いできますか？",
    "わかりました、すぐ対応します。",
    "キャンペーンの開始日は、十一月一日を予定しています。",
    "カメラマンと照明の手配は、制作会社にお願いしています。",
]
VOICES = ["Kyoko", "Reed (日本語（日本）)"]
check_voices(VOICES)
os.chdir(HERE)
refs = []
for vi, v in enumerate(VOICES):
    for si, s in enumerate(SENTENCES):
        name = f"dev/d{vi}_s{si:02d}.wav"
        refs.append({"file": name, "voice": v, "text": s, "sha256": synth(s, v, name)})
json.dump(refs, open("dev_refs.json", "w"), ensure_ascii=False, indent=1)
json.dump({"macos": environment(), "voices": VOICES}, open("dev_refs.json".replace(".json", ".meta.json"), "w"), indent=1)
print(len(refs), "clips")
