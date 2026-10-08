#!/usr/bin/env python3
"""複数の文を続けて話した評価用の音声を作る (refs_multi.json)。
1 文だけの評価では、kotoba が 2 文目以降を黙って落とす不具合を見逃したため。
make_testset.py の音声 (wav/) から、同じ声の 2〜4 文を 0.5〜2 秒の間を空けてつなぎ、
実際のマイクに近い小さな雑音 (RMS 0.001) を加える。乱数は固定なので毎回同じものができる。"""
import json
import os
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)
refs = json.load(open("refs.json"))
rng = np.random.default_rng(20260927)


def load(p):
    with wave.open(p) as w:
        return np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768


by_voice = {}
for r in refs:
    by_voice.setdefault(r["voice"], []).append(r)
os.makedirs("multi", exist_ok=True)
out = []
for vi, (voice, rs) in enumerate(sorted(by_voice.items())):
    for k in range(8):
        n = int(rng.integers(2, 5))
        pick = [rs[i] for i in rng.choice(len(rs), n, replace=False)]
        parts = [np.zeros(int(0.25 * 16000), np.float32)]          # pre-roll 相当
        for r in pick:
            parts += [load(r["file"]), np.zeros(int(rng.uniform(0.5, 2.0) * 16000), np.float32)]
        a = np.concatenate(parts)
        a = a + rng.normal(0, 0.001, len(a)).astype(np.float32)
        name = f"multi/m{vi}_{k:02d}.wav"
        with wave.open(name, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes((np.clip(a, -1, 1) * 32767).astype(np.int16).tobytes())
        out.append({"file": name, "voice": voice, "text": "".join(r["text"] for r in pick),
                    "sources": [r["file"] for r in pick], "seconds": round(len(a) / 16000, 1)})
json.dump(out, open("refs_multi.json", "w"), ensure_ascii=False, indent=1)
print(len(out), "multi-sentence clips,", f"{min(o['seconds'] for o in out)}–{max(o['seconds'] for o in out)}s")
