# JP Dictate

**English summary.** JP Dictate is a push-to-talk Japanese dictation app for macOS. Hold fn to record, release to paste the text at the cursor. Recognition runs entirely on the Mac, and audio never leaves the device.

- A native Swift menu-bar app with whisper.cpp embedded; no Python or Homebrew needed
- Two engines, switchable from the menu: Apple's built-in SpeechAnalyzer (fast, with punctuation) and kotoba-whisper on whisper.cpp with Metal (more accurate)
- Restores the clipboard after pasting, and cancels when fn is pressed together with another key
- Built entirely with Claude Code
- Requires macOS 26 on Apple Silicon

![JP Dictate menu](docs/menu.png)

The rest of this README is in Japanese.

---

macOS 用の、日本語に特化した push-to-talk 音声入力です。**fn を押している間だけ録音**し、離すとカーソル位置に貼り付けます。
認識はすべてこの Mac の中で行い、音声を外部に送りません。認識エンジンはメニューで選べます (下の「認識エンジン」)。

- Swift と whisper.cpp を組み込んだ単体のメニューバーアプリです (Dock には出ません。Python や Homebrew などは不要)
- fn と他のキーを同時に押したとき (fn+矢印 など) は録音を取り消します
- 貼り付けの前のクリップボードの内容 (画像なども含む) は、貼り付け後に元に戻します

## 動作環境

- macOS 26 以降、Apple Silicon
- ビルドには Xcode コマンドラインツール (`xcode-select --install`) と git。
  初回のビルドだけ whisper.cpp を取得してビルドします (数分。cmake と ninja がなければ uv で一時的に用意します)

## ビルドとインストール

```bash
./app/build.sh          # ~/Applications/JP Dictate.app を作成して起動
```

別の Mac で使うときは、できあがった `~/Applications/JP Dictate.app` をコピーするだけで動きます
(初回は Finder で右クリック →「開く」。Apple の公証がないため)。whisper.cpp はアプリの中に入っています (本体は約 4.7MB)。

初回はシステム設定 → プライバシーとセキュリティ で「JP Dictate」に次の許可を与えます。

| 許可 | 用途 |
|---|---|
| 入力監視 | fn キーの検知 |
| アクセシビリティ | カーソル位置への貼り付け (⌘V の送信) |
| マイク | 録音 (最初の起動時に確認が出ます) |

システム設定 → キーボード の「🌐キーを押して」は「何もしない」にしてください (絵文字パネルなどが一緒に開くため)。

### 署名について

`app/build.sh` はキーチェーンのコード署名用証明書「JP Dictate Signing」で署名します。同じ証明書で署名する限り、
アプリを作り直しても上の許可は外れません。証明書はキーチェーンアクセス → 証明書アシスタント → 証明書を作成
(固有名の種類: 自己署名ルート、証明書のタイプ: コード署名、有効期間は長めに) で作れます。
証明書なしで ad-hoc 署名にする場合は `JPD_ALLOW_ADHOC=1 ./app/build.sh` (作り直すたびに許可が外れます)。

## 認識エンジン

メニューバーのアイコン →「認識エンジン」で切り替えます (選んだものは次回の起動でも使います)。

| エンジン | 特徴 |
|---|---|
| Apple 内蔵 (既定) | macOS 26 の SpeechAnalyzer。軽く速い (応答 約 70ms)。句読点が付く。初回だけ日本語の認識アセットを macOS がダウンロード |
| kotoba-whisper | [kotoba-whisper v2.0](https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml) を whisper.cpp (Metal) で直接動かす。誤りが少ない (応答 約 0.3〜0.6 秒)。句読点はほぼ付かない。読み込み中は約 1.7GB のメモリを使う |

- kotoba-whisper のモデル (約 1.5GB) はアプリに入れず、`~/Library/Application Support/JPDictate/models/ggml-kotoba-whisper-v2.0.bin` に置きます。
  未ダウンロードのときに選ぶと確認が出て、「ダウンロード」を押すとメニューの「最後: …」の行に進み具合を出しながら取得し、終わると自動で切り替わります。
  このファイルを手で置いても構いません。消せば次に選んだときにまた確認が出ます
- Apple 内蔵に戻すとモデルはメモリから解放されます。切り替えに失敗したときは、前のエンジンのままエラーを表示します
- 起動時に kotoba-whisper を読み込めないとき (モデルがない等) は、Apple 内蔵で起動して選択も戻します
- kotoba-whisper のときだけ、無音・雑音で Whisper 系が出しがちな定番の幻覚フレーズ (「ご視聴ありがとうございました」など) を取り除きます
- whisper.cpp は v1.9.4 (`app/vendor/build-whisper.sh` に固定。`app/vendor/whisper.cpp` に取得して `app/vendor/build` にビルド。どちらも git 管理外)

## 認識の性能

`eval/` の読み上げ音声 (72 文 + 複数文 24 本) での測定 (M シリーズの Mac)。実際の声では変わることがあります。

| エンジン | 文字誤り率 | 読点 F1 | 句点 F1 | 応答 (中央値) |
|---|---|---|---|---|
| Apple 内蔵 | 4.2% (複数文 4.6%) | 0.67 | 0.97 | 約 70ms (複数文 145ms) |
| kotoba-whisper | 1.8% (複数文 0.9%) | 0.29 | 0.33 | 約 300ms (複数文 620ms) |

文字誤り率は句読点を除いて数えています。kotoba-whisper は文字は正確でも句読点をほとんど付けません。

## 設定 (環境変数)

| 変数 | 既定 | 内容 |
|---|---|---|
| `JPD_RESTORE` | 1 | 0 にすると貼り付け後にクリップボードを元に戻さない |
| `JPD_RESTORE_DELAY` | 1.5 | 貼り付けからクリップボードを戻すまでの秒数 |
| `JPD_SOUNDS` | 1 | 0 にすると開始/終了音を鳴らさない |
| `JPD_RMS_GATE` | 0.004 | 発話とみなす音量のしきい値 (30ms 単位の RMS) |
| `JPD_MIC_IDLE_SEC` | 300 | この秒数 Mac を操作しなければマイクを閉じる (0 で閉じない) |
| `JPD_LOG_TEXT` | 0 | 1 にするとログに認識した文章も書く |

アプリに渡すには `launchctl setenv JPD_SOUNDS 0` などで設定してから起動し直します。

## プライバシー

- 音声・文章を外部に送りません。録音はメモリの中だけで扱い、ディスクに書きません
  (ネットワークを使うのは、kotoba-whisper のモデルを最初にダウンロードするときだけです)
- ログ (`~/Library/Logs/JPDictate/dictate.log`) には認識した文章を書きません
- 貼り付け用のテキストはこの Mac だけに置き (ユニバーサルクリップボードで他の端末に送らない)、
  クリップボード管理アプリには一時的な内容として知らせます。パスワード管理アプリがコピーした内容は復元しません
- パスワード入力欄 (セキュア入力中) には貼り付けません。話している間に前面のアプリが変わったときは、貼り付けずにコピーだけします
- 5 分操作がないとマイクを閉じます (マイク使用中の表示が消え、Mac がスリープできます)

## 構成

| パス | 内容 |
|---|---|
| `app/Sources/` | アプリ本体 (Swift): キー検知 `Hotkey`、録音 `Recorder`、認識 `Transcriber` (Apple 内蔵)・`Kotoba` (kotoba-whisper)・`KotobaModel` (モデルのダウンロード)・`Engine` (エンジンの共通の形)、後処理 `TextCleaner`、貼り付け `Paster`、全体の流れ `Dictation`、メニュー `AppDelegate` |
| `app/build.sh` | ビルド・署名・インストール (whisper.cpp のビルドも呼び出す) |
| `app/vendor/build-whisper.sh` | whisper.cpp v1.9.4 を取得して静的ライブラリ (Metal 込み) にビルド |
| `app/icon/` | アイコンの生成 (減衰振動 e^{-t/τ} sin 2πft がテキストカーソルに変わるデザイン) |
| `eval/` | 評価用の読み上げ音声の生成、ベンチマーク (`bench_one.py`)、採点 (`score.py`) |

評価の例 (アプリの実行ファイルに `--transcribe-stdin` を付けると、WAV を認識するだけのモードになります):

```bash
cd eval && python3 -m venv .venv && .venv/bin/pip install numpy
python3 make_testset.py && python3 make_devset.py && .venv/bin/python make_multiset.py
python3 bench_one.py candidates/prod_swift refs.json results/prod_swift.json
python3 bench_one.py candidates/prod_swift_kotoba refs.json results/prod_swift_kotoba.json   # kotoba-whisper (モデルのダウンロードが必要)
python3 score.py results/*.json
```

`--engine kotoba` を付けると kotoba-whisper で認識します (既定は `apple`)。`JPD_APP_BIN` で別の実行ファイルを指定できます。

## 著作権 / Copyright

Copyright © 2026 Elik Shima. All rights reserved.

このリポジトリのソースコードは、参考のために公開しています。利用・改変・再配布の許可（ライセンス）は付与していません。
The source code in this repository is published for reference only. No license is granted to use, modify, or redistribute it.

組み込んでいる whisper.cpp は MIT ライセンスで、ビルド時に `app/vendor/build-whisper.sh` が取得します（このリポジトリには含みません）。
whisper.cpp (MIT License) is fetched at build time by `app/vendor/build-whisper.sh` and is not included in this repository.
