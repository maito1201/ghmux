# ghmux

GitHub の Issue / PR と Claude Code を 1 画面に統合する macOS ターミナル。

> ⚠️ Phase 0 実装中。詳細は [`CONCEPT.md`](./CONCEPT.md) と [`実装プラン`](#) を参照。

## 動作要件

- macOS 13 (Ventura) 以上 (arm64)
- `gh` CLI (認証済み): `brew install gh && gh auth login`


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
