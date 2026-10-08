"""評価用の読み上げ音声を作る共通処理 (make_testset.py / make_devset.py から使う)"""
import hashlib
import os
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def check_voices(voices):
    """指定した声がないと say は黙って別の声で読むので、先に確かめる"""
    have = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    names = {line.split("  ")[0].strip() for line in have.splitlines()}
    missing = [v for v in voices if v not in names]
    if missing:
        raise SystemExit(f"次の声がこの Mac にありません: {missing} (システム設定 → アクセシビリティ → 読み上げコンテンツ で追加)")


def synth(text, voice, out_path):
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with tempfile.TemporaryDirectory() as d:
        subprocess.run(["say", "-v", voice, "-o", f"{d}/a.aiff", text], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", f"{d}/a.aiff", out_path], check=True)
    return hashlib.sha256(open(out_path, "rb").read()).hexdigest()[:16]


def environment():
    return subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
