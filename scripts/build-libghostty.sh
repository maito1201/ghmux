#!/usr/bin/env bash
# build-libghostty.sh — vendor/ghostty から GhosttyKit.xcframework (macOS native only)
# を作って Sources/CGhostty/Vendored/ に配置する。
#
# 前提:
#   1. scripts/install-zig.sh が走っていて vendor/zig/0.15.2/zig が存在する
#   2. Xcode Command Line Tools (xcode-select --install) のみで OK
#      (Xcode.app は不要。macOS 26 SDK は Zig 0.15.2 の linker と相性が悪いので CLT を使う)
#
# パッチ依存:
#   vendor/zig/0.15.2/lib/std/zig/system/darwin/macos.zig
#       → ホスト OS バージョンを 26+ から 15.5 にクランプ
#   vendor/ghostty/src/build/GhosttyXCFramework.zig
#       → target=.native の時に iOS スライス初期化を skip
#
# 両パッチは scripts/patch-zig.sh / patch-ghostty.sh で適用する想定。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="$ROOT/vendor/ghostty"
ZIG="$ROOT/vendor/zig/0.15.2/zig"
OUT_DIR="$ROOT/Vendored"
XCFW_NAME="GhosttyKit.xcframework"

# DEVELOPER_DIR は Xcode.app に向ける — metal シェーダコンパイラのランタイム
# リソース (Metal Toolchain) が Xcode.app 経由でないと見えないため。
# 一方、Xcode.app の MacOSX26.5.sdk の libSystem.tbd には arm64-macos が含まれず
# (arm64e のみ)、Zig 0.15.2 のリンクが失敗する。CLT の MacOSX.sdk は arm64-macos を
# 含むのでこちらを使いたい。
#
# 解決: vendor/bin/xcrun ラッパーが `xcrun --sdk macosx --show-sdk-path` だけを
# 横取りして CLT パスを返す。それ以外のリクエスト (metal の検索/起動など) は本物の
# xcrun に流す。PATH の先頭に vendor/bin を入れることでこのラッパーが効く。
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$ROOT/vendor/bin:$PATH"
[ -d "$DEVELOPER_DIR" ] || { echo "✗ Xcode.app が見つかりません: $DEVELOPER_DIR" >&2; exit 1; }
[ -x "$ROOT/vendor/bin/xcrun" ] || { echo "✗ vendor/bin/xcrun ラッパーが無い" >&2; exit 1; }
[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ] || {
    echo "✗ CLT MacOSX.sdk が無い。xcode-select --install を実行してください" >&2; exit 1;
}

step() { printf "\n\033[1;34m▸ %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

[ -d "$GHOSTTY_DIR" ] || die "vendor/ghostty が見つかりません。git submodule update --init を実行してください"
[ -x "$ZIG" ]        || die "$ZIG が無いか実行不可。scripts/install-zig.sh を実行してください"

step "環境"
echo "  zig:          $($ZIG version)"
echo "  xcode-select: $(xcode-select -p)"
echo "  metal:        $(xcrun --find metal 2>/dev/null || echo '?')"
echo "  macOS SDK:    $(xcrun --show-sdk-path -sdk macosx 2>/dev/null || echo '?')"

step "Ghostty xcframework (macOS native のみ) ビルド"
cd "$GHOSTTY_DIR"
# -Dxcframework-target=native: iOS スライスは構築されない (パッチ適用済み GhosttyXCFramework が分岐)
# -Demit-xcframework=true: xcframework を install ターゲットに含める
# -Dapp-runtime=none: libghostty モード (macOS アプリ本体は作らない)
# -Demit-macos-app=false: フルアプリは不要
"$ZIG" build \
    -Doptimize=ReleaseFast \
    -Dapp-runtime=none \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Dxcframework-target=native

step "成果物の検索"
# GhosttyXCFramework.zig の out_path はプロジェクト相対なので zig-out 外に出る
XCFW_SRC=$(find "$GHOSTTY_DIR" -maxdepth 4 -type d -name "$XCFW_NAME" -prune 2>/dev/null | head -1)
[ -n "$XCFW_SRC" ] || die "$XCFW_NAME が vendor/ghostty/ 配下に見つかりません"
echo "  source: $XCFW_SRC"

step "Vendored/ に xcframework をコピー"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
rsync -a --delete "$XCFW_SRC/" "$OUT_DIR/$XCFW_NAME/"

step "CGhostty へ ghostty.h を同期"
# SwiftPM の CGhostty ターゲットが import する C ヘッダ。xcframework のヘッダと一致させる。
HDR_SRC="$OUT_DIR/$XCFW_NAME/macos-arm64/Headers/ghostty.h"
HDR_DST="$ROOT/Sources/CGhostty/include/ghostty.h"
[ -f "$HDR_SRC" ] || die "ghostty.h が xcframework 内に見つかりません: $HDR_SRC"
cp "$HDR_SRC" "$HDR_DST"
echo "  $HDR_DST"

step "GHOSTTY_RESOURCES_DIR 用リソースをコピー"
# terminfo (xterm-ghostty) / シェル統合スクリプト。Ghostty.App が setenv で参照する。
RES_SRC="$GHOSTTY_DIR/zig-out/share/ghostty"
RES_DST="$ROOT/Vendored/ghostty-resources"
if [ -d "$RES_SRC" ]; then
    rm -rf "$RES_DST"
    mkdir -p "$RES_DST"
    rsync -a "$RES_SRC/" "$RES_DST/"
    echo "  $RES_DST"
else
    echo "  (share/ghostty 未生成 — terminfo 同梱はスキップ)"
fi

step "完了"
echo "  xcframework: $OUT_DIR/$XCFW_NAME"
echo "  header:      $HDR_DST"
echo ""
echo "次は swift build / swift run gmux。"
