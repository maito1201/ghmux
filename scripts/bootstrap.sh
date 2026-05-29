#!/usr/bin/env bash
# bootstrap.sh — gmux の依存をローカルマシンに揃える。
# 初回 clone 後とプル後に実行する想定。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

step() { printf "\n\033[1;34m▸ %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m! %s\033[0m\n" "$*" >&2; }
die()  { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

require() {
    local cmd="$1"; local hint="$2"
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' が見つかりません。$hint"
}

step "依存ツールの確認"
require swift   "Xcode Command Line Tools (xcode-select --install) を入れてください"
require git     "git をインストールしてください"
require gh      "brew install gh && gh auth login を実行してください"
require zig     "brew install zig を実行してください"
command -v claude >/dev/null 2>&1 || warn "claude CLI が PATH にありません。後で設定してください"

step "Git submodule の取得 (vendor/ghostty)"
git submodule update --init --recursive

step "libghostty のビルド"
"$ROOT/scripts/build-libghostty.sh"

step "Swift Package のビルド"
swift build

step "完了"
echo "  swift run gmux  で起動できます。"
