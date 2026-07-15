#!/usr/bin/env bash
# 1024x1024 の PNG から macOS アプリ用 .icns を生成する。
# アイコンの差し替えは元 PNG (Packaging/AppIcon.png) を差し替えるだけで完結する
# よう、.icns はコミットせずビルド時 (CI / ローカル) にこのスクリプトで都度生成する。
#
# 使い方: scripts/make-icns.sh <input.png> <output.icns>
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <input.png> <output.icns>" >&2
  exit 2
fi

SRC="$1"
OUT="$2"

if [ ! -f "$SRC" ]; then
  echo "エラー: 入力 PNG が見つかりません: $SRC" >&2
  exit 1
fi

# 一時 .iconset を作り、終了時 (成功・失敗問わず) に必ず後始末する。
ICONSET="$(mktemp -d)/AppIcon.iconset"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT
mkdir -p "$ICONSET"

# iconutil が要求する 10 スロット (16/32/128/256/512 の @1x・@2x)。
# "サイズ ファイル名" の組で回し、sips で元 PNG からリサイズする。
for entry in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  size="${entry%% *}"
  name="${entry#* }"
  sips -z "$size" "$size" "$SRC" --out "$ICONSET/$name" >/dev/null
done

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "生成: $OUT"
