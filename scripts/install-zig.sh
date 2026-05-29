#!/usr/bin/env bash
# install-zig.sh — Ghostty が要求する Zig 0.15.2 を vendor/zig/0.15.2/ に固定インストールする。
#
# システムワイドな Zig (brew 等) のバージョンに依存しないために、
# プロジェクトローカルにバイナリ tarball を展開する方式を採用する。
# vendor/zig/ は .gitignore 対象。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG_VERSION="0.15.2"
ZIG_DIR="$ROOT/vendor/zig/$ZIG_VERSION"

step() { printf "\n\033[1;34m▸ %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

ARCH=$(uname -m)
case "$ARCH" in
    arm64|aarch64) ZIG_ARCH="aarch64" ;;
    x86_64)        ZIG_ARCH="x86_64" ;;
    *) die "未対応のアーキテクチャ: $ARCH" ;;
esac

OS=$(uname -s)
case "$OS" in
    Darwin) ZIG_OS="macos" ;;
    Linux)  ZIG_OS="linux" ;;
    *) die "未対応の OS: $OS" ;;
esac

TARBALL="zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_VERSION}.tar.xz"
URL="https://ziglang.org/download/${ZIG_VERSION}/${TARBALL}"

if [ -x "$ZIG_DIR/zig" ] && "$ZIG_DIR/zig" version 2>/dev/null | grep -qx "$ZIG_VERSION"; then
    step "既にインストール済み: $ZIG_DIR/zig ($ZIG_VERSION)"
    exit 0
fi

step "Zig $ZIG_VERSION をダウンロード: $URL"
mkdir -p "$ZIG_DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fL --progress-bar -o "$TMP/zig.tar.xz" "$URL"

step "展開"
tar -xJf "$TMP/zig.tar.xz" -C "$TMP"

# tarball 内のディレクトリ名 (zig-aarch64-macos-0.15.2) を ZIG_DIR にリネーム展開
EXTRACTED=$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'zig-*' | head -1)
[ -n "$EXTRACTED" ] || die "tarball の中身が想定と異なります"
# ZIG_DIR の中身を入れ替え
rm -rf "$ZIG_DIR"
mv "$EXTRACTED" "$ZIG_DIR"

step "確認"
"$ZIG_DIR/zig" version
echo "  → $ZIG_DIR/zig"
