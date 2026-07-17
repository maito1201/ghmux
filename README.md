# ghmux

GitHub の Issue / PR と Claude Code を 1 画面に統合する macOS ターミナル。
ターミナル上部にGitHubのIssue、またはPRのURLをペーストするとClaudeが立ち上がる。
PRのCI Fail, PASSなどの状況に応じて自動でプロンプトを入力させることが可能。

## 動作要件

- macOS 13 (Ventura) 以上 (arm64)
- `gh` CLI (認証済み): `brew install gh && gh auth login`


## インストール

[Releases](https://github.com/maito1201/ghmux/releases) から `ghmux-<version>-macos-arm64.dmg` を入手する。

1. `.dmg` を開き、`ghmux.app` を Applications へドラッグする。
2. 未署名のため、初回のみ Gatekeeper の隔離属性を解除する:

   ```sh
   xattr -dr com.apple.quarantine /Applications/ghmux.app
   ```

3. `ghmux.app` を起動する（Launchpad もしくは `open -a ghmux`）。

> ℹ️ 現在 ghmux は Apple のコード署名・公証を行っていないため、
> 上記の `xattr` 解除を行わないと「開発元を検証できません」と警告され起動できない。
> これはマルウェアではなく未署名アプリに対する macOS の標準動作。


## Claude Code スキルとして使う

起動中の ghmux GUI を Claude Code から操作するスキルを、プラグインとして配布している。
Claude Code 内で以下を実行するとインストールできる。

```sh
/plugin marketplace add maito1201/ghmux
/plugin install ghmux@ghmux
```

導入後、Claude が `ghmux` のペイン/ワークスペース操作（作成・一覧・内容確認・クローズ、Issue/PR 割り当て）を
CLI 経由で扱えるようになる。スキル本体は [`skills/ghmux/SKILL.md`](./skills/ghmux/SKILL.md)。


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
├── skills/ghmux/           # Claude Code スキル (SKILL.md)
└── .claude-plugin/         # プラグイン / marketplace マニフェスト
```
