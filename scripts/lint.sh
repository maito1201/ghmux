#!/usr/bin/env bash
# lint.sh — swift-format による軽い lint。
# swift-format は CLT 同梱版を利用 (なければ brew install swift-format)。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v swift-format >/dev/null 2>&1; then
    echo "swift-format が見つかりません。brew install swift-format" >&2
    exit 1
fi

swift-format lint --recursive --strict \
    Sources/gmux \
    Sources/GhosttyKit \
    Tests/gmuxTests
