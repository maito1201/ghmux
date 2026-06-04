# ghmux

GitHub の Issue / PR と Claude Code を 1 画面に統合する macOS ターミナル。
[cmux](https://github.com/manaflow-ai/cmux) の構成を参考に、libghostty を AppKit に組み込んでいる。

> ⚠️ Phase 0 実装中。詳細は [`CONCEPT.md`](./CONCEPT.md) と [`実装プラン`](#) を参照。

## 動作要件

- macOS 13 (Ventura) 以上 (arm64)
- Xcode Command Line Tools (`xcode-select --install`)
- [Homebrew](https://brew.sh/)
- `gh` CLI (認証済み): `brew install gh && gh auth login`
- `claude` CLI: <https://docs.anthropic.com/en/docs/claude-code>
- `zig` (libghostty ビルド用): `brew install zig`

## セットアップ

```sh
git clone --recursive <this-repo>
cd ghmux
./scripts/bootstrap.sh    # submodule + libghostty ビルド
swift run ghmux
```

## 開発

```sh
swift build              # ビルド
swift run ghmux           # 起動
swift test               # テスト
./scripts/lint.sh        # swift-format による lint
```

## 構成

```
ghmux/
├── Sources/ghmux/           # メインアプリ (AppKit)
├── Sources/GhosttyKit/     # libghostty の Swift ラッパ
├── Sources/CGhostty/       # ghostty.h を expose する C モジュール
├── Tests/ghmuxTests/        # 単体テスト
├── vendor/ghostty/         # Ghostty (git submodule)
├── scripts/                # ビルド / lint
└── CONCEPT.md              # 設計コンセプト
```

## ライセンス

未定。Ghostty は MIT。
