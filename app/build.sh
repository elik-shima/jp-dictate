#!/usr/bin/env bash
# JP Dictate.app をビルドして ~/Applications にインストールし、起動する (JPD_NO_LAUNCH=1 で起動しない)。
# 署名: キーチェーンのコード署名用証明書「JP Dictate Signing」(JPD_SIGN_ID で変更可) で署名する。
#       同じ証明書で署名する限り、作り直しても macOS の許可 (入力監視・アクセシビリティ) は外れない。
#       証明書がないときは止まる。ad-hoc 署名 (作り直すたびに許可が外れる) でよければ JPD_ALLOW_ADHOC=1。
# アイコン: app/AppIcon.icns と app/MenubarTemplate(@2x).png を組み込む (作り直しは app/icon/build_icons.py)。
set -euo pipefail
cd "$(dirname "$0")"
DEST="${1:-$HOME/Applications}"
SIGN_ID="${JPD_SIGN_ID:-JP Dictate Signing}"
# ビルドはリポジトリの外の一時フォルダで行い、最後に消す (同じ ID のアプリが 2 つ登録されたままにならないように)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/JP Dictate.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macosx26.0 Sources/*.swift -o "$APP/Contents/MacOS/JPDictate" \
  -framework AppKit -framework ServiceManagement -framework Speech -framework AVFoundation -framework Carbon -framework Security

for f in MenubarTemplate.png MenubarTemplate@2x.png; do
  [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/"
done
ICON_KEYS=""
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEYS="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>        <string>local.jp-dictate</string>
  <key>CFBundleName</key>              <string>JP Dictate</string>
  <key>CFBundleDisplayName</key>       <string>JP Dictate</string>
  <key>CFBundleExecutable</key>        <string>JPDictate</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>26.0</string>
  <key>LSUIElement</key>               <true/>
  ${ICON_KEYS}
  <key>NSMicrophoneUsageDescription</key>
  <string>押している間の音声を、このMac上で文字に変換するためにマイクを使います。音声は外部に送信しません。</string>
</dict>
</plist>
PLIST

# 自己署名の証明書は「信頼済み」ではないため -v (有効なものだけ) を付けずに探す。
# (grep -q をパイプで使うと、pipefail のもとで security が SIGPIPE を受けて「見つからない」扱いになることがある)
IDENTITIES="$(security find-identity -p codesigning)"
HASHES="$(printf '%s\n' "$IDENTITIES" | awk -v n="\"$SIGN_ID\"" 'index($0, n) { print $2 }' | sort -u)"
COUNT="$(printf '%s' "$HASHES" | grep -c . || true)"
if [ "$COUNT" -ge 1 ]; then
  HASH="$(printf '%s\n' "$HASHES" | head -1)"
  [ "$COUNT" -gt 1 ] && echo "⚠️  「$SIGN_ID」が $COUNT 個あります。$HASH を使います (不要なものはキーチェーンアクセスで削除してください)"
  codesign --force --sign "$HASH" --identifier local.jp-dictate "$APP"
  echo "署名: $SIGN_ID ($HASH)"
elif [ "${JPD_ALLOW_ADHOC:-0}" = "1" ]; then
  codesign --force --sign - --identifier local.jp-dictate "$APP"
  echo "⚠️  ad-hoc 署名にしました (作り直すたびに権限の許可が外れます)"
else
  echo "❌ コード署名用の証明書「$SIGN_ID」が見つかりません。"
  echo "   キーチェーンアクセス → 証明書アシスタント → 証明書を作成 (種類: 自己署名ルート / コード署名) で作るか、"
  echo "   ad-hoc 署名でよければ JPD_ALLOW_ADHOC=1 ./app/build.sh を実行してください。"
  exit 1
fi
codesign --verify "$APP"

mkdir -p "$DEST"
# 起動中なら終了させ、終了処理 (クリップボードの復元など) が終わるまで待つ
if pkill -x JPDictate 2>/dev/null; then
  for _ in $(seq 1 80); do pgrep -x JPDictate >/dev/null || break; sleep 0.1; done
  if pgrep -x JPDictate >/dev/null; then
    echo "❌ JP Dictate が終了しません。メニューから終了してから、もう一度実行してください。"
    exit 1
  fi
fi
rm -rf "$DEST/JP Dictate.app"
cp -R "$APP" "$DEST/"
echo "インストールしました: $DEST/JP Dictate.app"
if [ "${JPD_NO_LAUNCH:-0}" != "1" ]; then
  open "$DEST/JP Dictate.app"
fi
