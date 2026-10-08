#!/usr/bin/env bash
# whisper.cpp を取得して、静的ライブラリ (Metal 込み) を app/vendor/build に作る。何度実行しても安全 (作成済みなら何もしない)。
# 固定するバージョン: whisper.cpp v1.9.4 (コミット 927cfce34f31707e17f2bff35c349632fb9e2c3a)
# 必要なもの: Xcode コマンドラインツール、git、cmake と ninja (なければ uv で一時的に用意する)。
# Metal のシェーダーはライブラリに埋め込む (GGML_METAL_EMBED_LIBRARY) ので、metal コンパイラ (Xcode 本体) は不要。
set -euo pipefail
cd "$(dirname "$0")"
TAG="v1.9.4"
SHA="927cfce34f31707e17f2bff35c349632fb9e2c3a"
SRC="$PWD/whisper.cpp"
BUILD="$PWD/build"
STAMP="$BUILD/.built-$SHA"

if [ -f "$STAMP" ] && [ -f "$BUILD/lib/libwhisper.a" ]; then
  exit 0
fi

# ソースの用意 (固定したコミットに合わせる)
if [ ! -d "$SRC/.git" ]; then
  git clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/whisper.cpp "$SRC"
fi
if [ "$(git -C "$SRC" rev-parse HEAD)" != "$SHA" ]; then
  git -C "$SRC" fetch --quiet --depth 1 origin "tag" "$TAG"
  git -C "$SRC" checkout --quiet "$SHA"
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$SHA" ] || { echo "❌ whisper.cpp が $TAG ($SHA) ではありません" >&2; exit 1; }

# cmake / ninja (PATH になければ uv で一時環境に入れる)
TOOLS="${JPD_BUILD_TOOLS:-$PWD/.tools}"
if ! command -v cmake >/dev/null || ! command -v ninja >/dev/null; then
  if [ ! -x "$TOOLS/bin/cmake" ] || [ ! -x "$TOOLS/bin/ninja" ]; then
    command -v uv >/dev/null || { echo "❌ cmake と ninja が必要です (brew install cmake ninja、または uv を入れてください)" >&2; exit 1; }
    uv venv --quiet "$TOOLS"
    uv pip install --quiet --python "$TOOLS/bin/python" cmake ninja
  fi
  export PATH="$TOOLS/bin:$PATH"
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"
cmake -S "$SRC" -B "$BUILD/cmake" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_METAL_NDEBUG=ON \
  -DGGML_BLAS=OFF -DGGML_ACCELERATE=ON -DGGML_NATIVE=OFF -DGGML_CCACHE=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_BUILD_EXAMPLES=OFF -DGGML_BUILD_TESTS=OFF \
  -DCMAKE_INSTALL_PREFIX="$BUILD" >/dev/null
cmake --build "$BUILD/cmake" --config Release -j "$(sysctl -n hw.ncpu)" >/dev/null
cmake --install "$BUILD/cmake" >/dev/null
touch "$STAMP"
echo "whisper.cpp $TAG をビルドしました: $BUILD"
