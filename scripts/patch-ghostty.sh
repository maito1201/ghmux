#!/usr/bin/env bash
# patch-ghostty.sh — vendor/ghostty に macOS-only ビルド用のパッチを当てる。
#
# 必要な理由:
#   Ghostty の GhosttyXCFramework.init は target=.native でも iOS スライスを eager に
#   構築するため iOS SDK が必須になる。iOS SDK は Xcode.app に含まれるが、Zig 0.15.2 と
#   macOS 26 SDK の組み合わせは linker 段で失敗するため、結果的に CLT のみで完結させたい。
#   このパッチで target=.native のときは macOS スライスのみ構築するようにする。
#
# 冪等: 既に適用済みなら何もしない。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/vendor/ghostty/src/build/GhosttyXCFramework.zig"
MARKER="ghmux patch: with -Dxcframework-target=native"

[ -f "$TARGET" ] || { echo "✗ $TARGET が無い。git submodule update --init を先に実行してください" >&2; exit 1; }

if grep -q "$MARKER" "$TARGET"; then
    echo "▸ Ghostty パッチは既に適用済み"
    exit 0
fi

echo "▸ Ghostty GhosttyXCFramework.init に native-only 分岐を挿入"

python3 - <<'PY'
import sys, pathlib

p = pathlib.Path("vendor/ghostty/src/build/GhosttyXCFramework.zig")
src = p.read_text()

old = """pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
    target: Target,
) !GhosttyXCFramework {
    // Universal macOS build
    const macos_universal = try GhosttyLib.initMacOSUniversal(b, deps);"""

new = """pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
    target: Target,
) !GhosttyXCFramework {
    // ghmux patch: with -Dxcframework-target=native we skip iOS slice initialisation
    // entirely. The original code unconditionally constructs the iOS targets which
    // forces the build to find an iOS SDK (Xcode.app) even when the caller only wants
    // a macOS-only xcframework. Skipping it means we can build with Command Line Tools
    // alone (CLT's MacOSX.sdk works with Zig 0.15.2; Xcode.app's MacOSX26.5.sdk does
    // not — its libSystem.tbd format trips Zig 0.15.2's linker).
    if (target == .native) {
        const macos_native_only = try GhosttyLib.initStatic(b, &try deps.retarget(
            b,
            Config.genericMacOSTarget(b, null),
        ));

        const wf_native = b.addWriteFiles();
        _ = wf_native.addCopyFile(b.path("include/ghostty.h"), "ghostty.h");
        _ = wf_native.addCopyFile(b.path("include/module.modulemap"), "module.modulemap");
        const headers_native = wf_native.getDirectory();

        const xcfw_native = XCFrameworkStep.create(b, .{
            .name = "GhosttyKit",
            .out_path = "macos/GhosttyKit.xcframework",
            .libraries = &.{
                .{
                    .library = macos_native_only.output,
                    .headers = headers_native,
                    .dsym = macos_native_only.dsym,
                },
            },
        });

        return .{ .xcframework = xcfw_native, .target = target };
    }

    // Universal macOS build
    const macos_universal = try GhosttyLib.initMacOSUniversal(b, deps);"""

if old not in src:
    sys.exit("✗ 想定パターンが見つかりませんでした。Ghostty のバージョンが想定と違うかもしれません。")
p.write_text(src.replace(old, new))
print("  パッチ適用完了")
PY
