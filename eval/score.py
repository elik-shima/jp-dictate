#!/usr/bin/env python3
"""bench_one.py の結果を採点する。 usage: python3 score.py results/*.json
   CER        : 句読点・空白を除き、数字表記と少数の表記ゆれを揃えた文字誤り率 (分母は揃える前の正解の文字数)
   95%CI      : 文単位ブートストラップによる CER の 95% 信頼区間 (同じ文の複数の声はまとめて扱う)
   文字一致   : 句読点を除いて完全に一致した件数 / 句読点も一致: 句読点の位置まで一致した件数
   読点F1     : 「、」の位置の一致 (文字を編集距離で整列して比較)
   句点F1     : 文末記号「。？！」の位置の一致
   エラー     : 認識に失敗した件数 (CER では全文欠落として数え、遅延の集計からは除く)
"""
import json
import math
import random
import re
import statistics
import sys
import unicodedata

# 句読点など (CER では無視する)。三点リーダーは句読点の評価の対象外。
PUNCT = set("、。，．,.？?！!「」『』・ 　…（）()【】―—")
END = set("。．.？?！!")
COMMA = set("、，,")
KNUM = {"〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
KUNIT = {"十": 10, "百": 100, "千": 1000}
KBIG = {"万": 10 ** 4, "億": 10 ** 8, "兆": 10 ** 12}
DECIMAL = "∙"   # 数字の間の小数点の代わり (句読点として数えない)
# 正解と認識結果の両方に同じように適用する表記ゆれ (語単位でのみ置き換える)
VARIANTS = [
    ("トー&マナー", "トーンアンドマナー"), ("トーン&マナー", "トーンアンドマナー"), ("&", "アンド"),
    ("Slack", "スラック"), ("PDF", "ＰＤＦ"), ("下さい", "ください"),
    ("私の方で", "私のほうで"), ("私の方に", "私のほうに"), ("お疲れ様", "お疲れさま"),
]


def kanji_to_int(s: str) -> int:
    toks = re.findall(r"\d+|.", s)
    if all(t.isdigit() or t in KNUM for t in toks):
        # 位取りの漢数字 (二〇二六) やアラビア数字だけのときは、そのまま並べる
        return int("".join(t if t.isdigit() else str(KNUM[t]) for t in toks))
    total, sec, cur = 0, 0, 0
    for tok in toks:
        if tok.isdigit():
            cur = int(tok)
        elif tok in KNUM:
            cur = KNUM[tok]
        elif tok in KUNIT:
            sec += (cur or 1) * KUNIT[tok]
            cur = 0
        elif tok in KBIG:
            total += ((sec + cur) or 1) * KBIG[tok]
            sec = cur = 0
    return total + sec + cur


def norm_numbers(s: str) -> str:
    """数字を 1 つの表記に揃える。数字 (0-9 または 〇一…九) を含まない「万」「千」などの語はそのまま。"""
    def conv(m):
        run = m.group()
        if not re.search(r"[0-9〇零一二三四五六七八九]", run) and run in ("百", "千", "万", "億", "兆"):
            return run   # 千葉・万全・百貨店 など、数字のない単位の 1 文字は語の一部とみなす
        return str(kanji_to_int(run))
    return re.sub(r"[0-9〇零一二三四五六七八九十百千万億兆]+", conv, s)


def nfkc(s: str) -> str:
    s = unicodedata.normalize("NFKC", s)
    s = re.sub(r"(?<=\d),(?=\d{3}(?!\d))", "", s)      # 5,000,000 の桁区切り
    s = re.sub(r"(?<=\d)\.(?=\d)", DECIMAL, s)          # 3.5 の小数点
    s = s.replace("...", "…")
    for a, b in VARIANTS:
        s = s.replace(unicodedata.normalize("NFKC", a), unicodedata.normalize("NFKC", b))
    return s


def strip(s: str) -> str:
    return "".join(c for c in s if c not in PUNCT)


def labels(s: str):
    """句読点を除いた文字列と、各文字の直後に付く記号の種類 ('、' / '。' / None)"""
    chars, labs = [], []
    for c in s:
        if c in COMMA or c in END:
            if labs:
                labs[-1] = "、" if c in COMMA else "。"
        elif c not in PUNCT:
            chars.append(c)
            labs.append(None)
    return "".join(chars), labs


def edit_distance(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def align(a: str, b: str) -> dict:
    """編集距離の逆追跡で、b の各位置に対応する a の位置を返す (一致と置換を対応とみなす)"""
    n, m = len(a), len(b)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] != b[j - 1]))
    pairs, i, j = {}, n, m
    while i > 0 and j > 0:
        if d[i][j] == d[i - 1][j - 1] + (a[i - 1] != b[j - 1]):
            pairs[j - 1] = i - 1
            i, j = i - 1, j - 1
        elif d[i][j] == d[i - 1][j] + 1:
            i -= 1
        else:
            j -= 1
    return pairs


def punct_counts(ref: str, hyp: str):
    rs, rl = labels(ref)
    hs, hl = labels(hyp)
    m = align(rs, hs)
    if rs and hs:
        m[len(hs) - 1] = len(rs) - 1   # 発話の末尾どうしは常に対応させる (最後の文字の誤認識で文末記号を失点しない)
    c = {p: [0, 0, 0] for p in "、。"}  # tp, fp, fn
    matched_ref = set()
    for j, lab in enumerate(hl):
        if lab is None:
            continue
        i = m.get(j)
        if i is not None and rl[i] == lab and i not in matched_ref:
            c[lab][0] += 1
            matched_ref.add(i)
        else:
            c[lab][1] += 1
    for i, lab in enumerate(rl):
        if lab is not None and i not in matched_ref:
            c[lab][2] += 1
    return c


def f1(tp, fp, fn):
    return 2 * tp / (2 * tp + fp + fn) if tp + fp + fn else 1.0


def row_errors(r):
    ref_raw = strip(nfkc(r["text"]))
    ref = strip(norm_numbers(nfkc(r["text"])))
    hyp = strip(norm_numbers(nfkc(r.get("hyp") or "")))
    return edit_distance(ref, hyp), len(ref_raw)


def bootstrap_ci(rows, iters=1000, seed=0):
    """文 (同じ正解文の全ての声) を単位にしたブートストラップ"""
    groups = {}
    for r in rows:
        e, n = row_errors(r)
        g = groups.setdefault(r["text"], [0, 0])
        g[0] += e
        g[1] += n
    gs = list(groups.values())
    rnd = random.Random(seed)
    vals = []
    for _ in range(iters):
        s = [gs[rnd.randrange(len(gs))] for _ in gs]
        vals.append(100 * sum(x[0] for x in s) / max(1, sum(x[1] for x in s)))
    vals.sort()
    return vals[int(0.025 * iters)], vals[int(0.975 * iters) - 1]


def score(path):
    d = json.load(open(path))
    rows = d["rows"]
    errs = chars = exact = exact_p = failed = 0
    pc = {p: [0, 0, 0] for p in "、。"}
    for r in rows:
        if r.get("error"):
            failed += 1
        e, n = row_errors(r)
        errs += e
        chars += n
        exact += e == 0
        ref, hyp = norm_numbers(nfkc(r["text"])), norm_numbers(nfkc(r.get("hyp") or ""))
        exact_p += e == 0 and labels(ref) == labels(hyp)
        for p, v in punct_counts(ref, hyp).items():
            for k in range(3):
                pc[p][k] += v[k]
    ms = sorted(x["ms"] for x in rows if not x.get("error"))
    lo, hi = bootstrap_ci(rows)
    return {
        "candidate": d["candidate"],
        "CER%": round(100 * errs / chars, 2),
        "95%CI": f"{lo:.1f}–{hi:.1f}",
        "文字一致": f"{exact}/{len(rows)}",
        "句読点も一致": f"{exact_p}/{len(rows)}",
        "読点F1": round(f1(*pc["、"]), 3),
        "句点F1": round(f1(*pc["。"]), 3),
        "中央値ms": round(statistics.median(ms)) if ms else "-",
        "p90ms": round(ms[math.ceil(0.9 * len(ms)) - 1]) if ms else "-",
        "最大ms": round(ms[-1]) if ms else "-",
        "エラー": failed,
        "ロード秒": d["load_s"],
    }


def main():
    rows = [score(p) for p in sys.argv[1:]]
    keys = list(rows[0])
    print(" | ".join(keys))
    for r in rows:
        print(" | ".join(str(r[k]) for k in keys))


if __name__ == "__main__":
    main()
