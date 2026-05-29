#!/usr/bin/env bash
# patch-zig.sh — vendor/zig/0.15.2 の標準ライブラリにパッチを当てる。
#
# 必要な理由:
#   macOS 26.x はネーミング変更 (旧 16) で 2025-10 リリースの Zig 0.15.2 リリース後に登場。
#   Zig 0.15.2 のホスト OS 検出 (std/zig/system/darwin/macos.zig) は macOS 26 を 26 と認識
#   するが、その状態で link command を組み立てると libSystem シンボルが解決できず失敗する。
#   ここでは検出結果を 15.5 にクランプして既知の良好な経路に乗せる。
#
# 冪等: 既に適用済みなら何もしない。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/vendor/zig/0.15.2/lib/std/zig/system/darwin/macos.zig"
MARKER="gmux patch: Zig 0.15.2 doesn't know"

[ -f "$TARGET" ] || { echo "✗ $TARGET が無い。scripts/install-zig.sh を先に実行してください" >&2; exit 1; }

if grep -q "$MARKER" "$TARGET"; then
    echo "▸ Zig パッチは既に適用済み"
    exit 0
fi

echo "▸ Zig macOS 検出ロジックにクランプを適用"

python3 - <<'PY'
import re, sys, pathlib

p = pathlib.Path("vendor/zig/0.15.2/lib/std/zig/system/darwin/macos.zig")
src = p.read_text()

old = """            if (parseSystemVersion(bytes)) |ver| {
                // never return non-canonical `10.(16+)`
                if (!(ver.major == 10 and ver.minor >= 16)) {
                    target_os.version_range.semver.min = ver;
                    target_os.version_range.semver.max = ver;
                    return;
                }
                continue;
            } else |_| {"""

new = """            if (parseSystemVersion(bytes)) |parsed_ver| {
                // gmux patch: Zig 0.15.2 doesn't know how to link against macOS 26+
                // host (released after Zig 0.15.2). Clamp to 15.5 so the linker
                // uses the well-known macOS 15 ABI conventions. Remove this when
                // we move to a Zig version that natively understands macOS 26.
                const ver: std.SemanticVersion = if (parsed_ver.major >= 16)
                    .{ .major = 15, .minor = 5, .patch = 0 }
                else
                    parsed_ver;
                // never return non-canonical `10.(16+)`
                if (!(ver.major == 10 and ver.minor >= 16)) {
                    target_os.version_range.semver.min = ver;
                    target_os.version_range.semver.max = ver;
                    return;
                }
                continue;
            } else |_| {"""

if old not in src:
    sys.exit("✗ 想定パターンが見つかりませんでした。Zig のバージョンが想定と違うかもしれません。")
p.write_text(src.replace(old, new))
print("  パッチ適用完了")
PY
