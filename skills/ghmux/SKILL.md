---
name: ghmux
description: 起動中の ghmux (macOS ターミナル多重化 GUI) をコマンドラインから操作する。ペイン/ワークスペースの作成・一覧・内容確認・クローズ、GitHub Issue/PR の割り当てを行う。ghmux のペイン内で作業しているとき、または別ターミナルから ghmux を制御したいときに使う。
---

# ghmux CLI

`ghmux` は GitHub の Issue/PR と Claude Code を 1 画面に統合する macOS ターミナルです。
引数なしで起動すると GUI アプリになり、サブコマンドを付けて実行すると**起動中の GUI へ指令を送る CLI クライアント**として動きます。

## 前提

- **GUI が起動していること**が必須。未起動時は各コマンドが「ghmux に接続できません」を stderr に出し、終了コード 2 で失敗します。
- CLI と GUI は Unix domain socket (`~/.config/ghmux/ghmux.sock`) 経由で通信します。
- **別ターミナルからでも実行可能**です（環境変数 `GHMUX_SOCK` は任意）。ghmux のペイン内で実行した場合は環境変数 `GHMUX_PANE` から「由来ペイン」が自動的に決まり、対象を省略したコマンドの基点になります。
- 対象 ID（pane_id / workspace_id）は `ghmux pane list` で取得します。

## 用語と階層

```
ghmux (GUI)
└─ workspace (複数、左下の一覧で切替。独立した分割ツリーを持つ)
   └─ pane (複数、端末 + GitHub Issue/PR ヘッダ)
```

- **pane**: 1 つの端末。Issue/PR を割り当てると Claude Code が起動し、PR の CI などを自動監視します。
- **workspace**: pane の分割ツリーを 1 つ持つ作業単位。
- ID はいずれも安定した UUID 文字列です（並べ替え・クローズで変わりません）。

## コマンド一覧

### `ghmux pane new [--issue <URL>] [--direction right|down] [--cwd <path>]`

新しいペインを作成します。

- `--issue <URL>`: GitHub の Issue または PR の URL を割り当てる（任意）。割り当てると Claude Code が起動し、Issue 取得・PR 探索・CI 監視まで自動で走ります。省略すると素のシェルペインを開きます。
- `--direction right|down`: 分割方向（既定 `right`）。
- `--cwd <path>`: 新ペインの作業ディレクトリ（省略時は由来ペインの cwd を引き継ぐ）。
- 基点ペイン: `GHMUX_PANE`（由来ペイン）→ アクティブペイン → 先頭ペイン の順にフォールバック。
- **出力**: `opened pane <pane_id>`（成功時、終了コード 0）。

```sh
ghmux pane new
ghmux pane new --issue https://github.com/owner/repo/issues/42 --direction down
```

### `ghmux pane list`

全ワークスペース/ペインの階層を整形 JSON で出力します。ID の取得や状態確認に使います。

- **出力**（`pretty-printed` JSON、キー名昇順）:

```jsonc
{
  "paneCount": 2,
  "workspaces": [
    {
      "id": "<workspace_id>",
      "name": "repo",            // 表示名 (ユーザー命名 > cwd 名 > "shell")
      "selected": true,           // 現在選択中のワークスペースか
      "panes": [
        {
          "paneId": "<pane_id>",
          "workingDirectory": "/path/to/dir",  // 取得不可なら省略
          "active": true,                       // ワークスペース内のフォーカス中ペインか
          "issue": {                            // Issue 割り当て時のみ
            "url": "https://github.com/owner/repo/issues/42",
            "state": "open"                     // "open" | "closed"
          },
          "pullRequests": [                     // 紐づく PR (無ければ空配列)
            {
              "url": "https://github.com/owner/repo/pull/43",
              "number": 43,
              "state": "open",                  // "open" | "closed" | "merged"
              "ci": "success",                  // "none" | "pending" | "success" | "failure"
              "failingChecks": ["build"]        // ci が "failure" のときのみ
            }
          ]
        }
      ]
    }
  ]
}
```

- `issue`/`pullRequests` の状態は非同期に取得・監視されるため、割り当て直後は反映まで数秒かかることがあります。
- `jq` での加工が可能です（例: `ghmux pane list | jq -r '.workspaces[].panes[].paneId'`）。

### `ghmux pane view <pane_id> [--viewport] [--lines <N>]`

指定ペインの端末内容をテキストで出力します。ペインで何が起きたかを確認するのに使います。

- 既定: **スクロールバック全体**（画面外の履歴も含む）。
- `--viewport`: 現在表示中の範囲のみ。
- `--lines <N>`: 末尾 N 行だけ返す（tail 相当。`--viewport` とも併用可）。
- **出力**: 端末テキストを stdout へそのまま。ペインが見つからなければ stderr にエラー、終了コード 1。

> ⚠️ **コンテキスト消費に注意**: 既定のスクロールバック全体は、長時間動いた端末だと数万行・数十万トークンに達し得ます。
> Claude が読む場合は、まず `--viewport`（可視範囲）か `--lines <N>`（例 `--lines 200`）で**必要な範囲に絞って**取得し、
> 全体が本当に必要なときだけ無指定にしてください。

```sh
ghmux pane view <pane_id> --lines 200      # 直近 200 行だけ (推奨)
ghmux pane view <pane_id> --viewport       # 可視範囲だけ
ghmux pane view <pane_id>                   # 全スクロールバック (大きくなり得る)
```

### `ghmux pane send <pane_id> <command> [--no-enter]`

指定ペインの端末へ文字列を送ります。**別ペインで unix コマンドを実行する**、あるいは**そのペインで動いている claude へ指示を投入する**のに使います。

- `<pane_id>`: 送信先（**明示必須**。誤実行を避けるため由来ペインへの暗黙フォールバックはしません）。`pane list` で取得します。
- `<command>`: 送る文字列。`pane view` と同じ単一位置引数なので、スペースを含む場合は**クォート必須**（例 `"npm test"`）。
- 既定は**貼り付け＋Enter で実行確定**します。`--no-enter` を付けると入力欄に置くだけで実行しません。
- 先頭が `--` のコマンドを送るときは `--`（end-of-options）の後ろに置きます: `ghmux pane send <id> -- --version`。
- 送信先で claude が動いている場合、この送信は**プロンプト投入**として扱われます。
- **出力**: 送信先 `<pane_id>`（成功時）。ペインが見つからなければ stderr にエラー、終了コード 1。

```sh
ghmux pane send <pane_id> "npm test"           # 別ペインでコマンド実行
ghmux pane send <pane_id> "このテストを直して"    # claude ペインへ指示を投入
ghmux pane send <pane_id> "git status" --no-enter  # 入力欄に置くだけ (未実行)
```

> ⚠️ 既定で実行まで行うため、`<pane_id>` を取り違えると意図しないペインでコマンドが走ります。送信前に `pane list` で対象を確認してください。

### `ghmux pane attach <pane_id> <URL> [--no-prompt]`

**既存のペイン**に GitHub の Issue または PR の URL を紐付けます。`pane new --issue` と違い **claude は起動しません**。そのペインで既に動いているエージェントに、ヘッダ表示と PR/CI 監視（CI 失敗・レビュー追加などの自動プロンプト）だけを付け足す用途です。

- `<pane_id>`: 紐付け先（**明示必須**。誤紐付けを避けるため由来ペインへの暗黙フォールバックはしません）。自分のペインなら `$GHMUX_PANE`。
- `<URL>`: Issue URL または PR URL。それ以外は stderr にエラー、終了コード 1。
- Issue URL: Issue をヘッダに表示し、その Issue を参照する PR の探索と CI 監視を始めます。
- PR URL: PR 行を追加して CI 監視を始めます。ペインに既に Issue が載っていればヘッドラインは Issue のまま残し、PR 行だけ足します。紐付けた PR は Issue の PR 探索結果に無くても外されません。
- 紐付け後、CI 失敗などの状態変化は**そのペインの端末へ自動プロンプトとして投入**されます（`pane send` と同じ経路）。
- `--no-prompt`: 自動プロンプトを流さず、ヘッダ表示と CI 監視（`pane list` での状態確認）だけ行います。そのペインで claude が動いていない、または人間が手動で対処したいときに使います。設定はペイン単位で、同じペインへ再度 attach したときは最後の指定が有効です。
- URL の形式検証は同期、GitHub からの取得・監視は非同期です。`pane list` への反映まで数秒かかります。取得失敗はペインのヘッダに表示されます。
- **出力**: 紐付け先 `<pane_id>`（成功時）。ペインが見つからなければ stderr にエラー、終了コード 1。

```sh
ghmux pane attach "$GHMUX_PANE" https://github.com/owner/repo/pull/43   # 自分のペインに作成した PR を紐付け
ghmux pane attach <pane_id> https://github.com/owner/repo/issues/42       # 別ペインに Issue を紐付け
ghmux pane attach <pane_id> https://github.com/owner/repo/pull/43 --no-prompt  # 監視のみ (端末へは何も流さない)
```

> 💡 Claude が会話の中で PR を作成したら、この作成直後に自分のペインへ紐付けておくと、以後 CI が落ちたときに ghmux から自動で通知 (プロンプト) が届きます。

### `ghmux pane close [<pane_id>]`

ペインを閉じます。

- `<pane_id>` 省略時は由来ペイン（`GHMUX_PANE`）→ アクティブペインの順で対象を決めます。
- **ワークスペース内で最後の 1 枚は閉じられません**（エラー、終了コード 1）。ワークスペースごと閉じたい場合は `workspace close` を使います。
- **出力**: 閉じた `<pane_id>`（成功時）。

### `ghmux workspace new`

新しいワークスペースを作成して選択します。現在のワークスペースの作業ディレクトリを引き継ぎます。

- **出力**: 新しい `<workspace_id>`（成功時）。

### `ghmux workspace close [<workspace_id>]`

ワークスペースを閉じます。

- `<workspace_id>` 省略時は由来ペインのワークスペース → 選択中ワークスペースの順で対象を決めます。
- **最後の 1 個は閉じられません**（エラー、終了コード 1）。
- **出力**: 閉じた `<workspace_id>`（成功時）。

## 終了コード

- `0`: 成功
- `1`: 指令は届いたが GUI 側で失敗（対象が見つからない、最後の 1 個を閉じようとした等）。理由は stderr。
- `2`: GUI へ接続できない / 引数エラー。

## 典型的なワークフロー

**ペイン内の Claude が作業を分岐させる**（`GHMUX_PANE` が自動で基点になる）:

```sh
# 関連 Issue を隣に開いて別の Claude に任せる
ghmux pane new --issue https://github.com/owner/repo/issues/99 --direction down
```

**別ターミナルから状態を俯瞰する**:

```sh
ghmux pane list                                   # 全体像と ID を取得
ghmux pane view <pane_id> --lines 200              # 特定ペインの直近を確認 (範囲を絞る)
ghmux pane list | jq '.workspaces[].panes[]
  | select(.pullRequests[]?.ci == "failure")'      # CI 失敗中のペインを抽出
```

**会話中に作った PR を自分のペインへ紐付ける**（以後 CI 失敗が自動プロンプトで届く）:

```sh
gh pr create --fill                                # → https://github.com/owner/repo/pull/43
ghmux pane attach "$GHMUX_PANE" https://github.com/owner/repo/pull/43
```

**別ペインへ作業を指示する**（`pane list` で対象を確認してから送る）:

```sh
ghmux pane send <pane_id> "npm test"               # 別ペインでコマンド実行
ghmux pane send <pane_id> "CI が失敗しているので直して"   # claude ペインへ指示
```

**後始末**:

```sh
ghmux pane close <pane_id>
ghmux workspace close <workspace_id>
```
