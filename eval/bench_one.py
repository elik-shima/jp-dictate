#!/usr/bin/env python3
"""1 候補を評価する。候補ディレクトリの adapter.py を読み込み、各 wav を順に認識して時間を測る。
   usage: <候補の python> bench_one.py <候補dir> <refs.json> <out.json>
   標準ライブラリのみ使用 (候補ごとの venv で動かすため)。

adapter.py の約束:
   class Engine:
       def __init__(self): ...           # モデルのロード・常駐プロセスの起動 (時間は計測対象外)
       def transcribe(self, wav_path: str) -> str: ...   # 16kHz mono int16 wav → テキスト
       def close(self): ...              # 起動したプロセスを止める
"""
import importlib.util
import json
import pathlib
import statistics
import sys
import time

EVAL = pathlib.Path(__file__).resolve().parent


def main():
    cand = pathlib.Path(sys.argv[1]).resolve()
    refs = json.load(open(sys.argv[2]))
    out = sys.argv[3]
    sys.path.insert(0, str(cand))
    spec = importlib.util.spec_from_file_location("adapter", cand / "adapter.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    t = time.perf_counter()
    eng = mod.Engine()
    load_s = time.perf_counter() - t
    rows = []
    try:
        for w in sorted((EVAL / "dev").glob("*.wav"))[:3]:  # ウォームアップ
            eng.transcribe(str(w))
        for r in refs:
            t = time.perf_counter()
            try:
                text, err = eng.transcribe(str(EVAL / r["file"])), None
            except Exception as e:  # 1 件の失敗で全体を失わない (score.py は全文欠落として数える)
                text, err = "", repr(e)
            ms = (time.perf_counter() - t) * 1000
            rows.append({**r, "hyp": text, "ms": round(ms, 1), **({"error": err} if err else {})})
            print(f"{ms:6.0f}ms  {err or text}", flush=True)
    finally:
        eng.close()
        ms = [x["ms"] for x in rows if not x.get("error")]
        if rows:  # 途中で止まっても、そこまでの結果は残す
            json.dump({"candidate": cand.name, "load_s": round(load_s, 2),
                       "ms_median": statistics.median(ms) if ms else None, "rows": rows},
                      open(out, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
