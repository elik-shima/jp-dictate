"""Swift 版 JP Dictate の kotoba-whisper エンジン (whisper.cpp 組み込み。TextCleaner と幻覚フレーズ除去の後処理まで) をそのまま評価する。
   ビルドした app の実行ファイルを --transcribe-stdin で常駐させる。JPD_APP_BIN で別の実行ファイルを指定できる。"""
import json
import os
import subprocess

BIN = os.environ.get("JPD_APP_BIN", os.path.expanduser("~/Applications/JP Dictate.app/Contents/MacOS/JPDictate"))


class Engine:
    def __init__(self):
        self.p = subprocess.Popen([BIN, "--transcribe-stdin", "--engine", "kotoba"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, encoding="utf-8", bufsize=1)
        info = json.loads(self.p.stdout.readline() or '{"fatal": "exited"}')
        if "fatal" in info:
            raise RuntimeError(info["fatal"])

    def transcribe(self, wav_path):
        self.p.stdin.write(os.path.abspath(wav_path) + "\n")
        self.p.stdin.flush()
        r = json.loads(self.p.stdout.readline())
        if "error" in r:
            raise RuntimeError(r["error"])
        return r["text"]

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=10)
