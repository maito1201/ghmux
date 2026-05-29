import Foundation

/// PR の状態変化イベントを、Claude に送るプロンプト文字列に変換するルールエンジン。
///
/// テンプレートは初期値 (`Templates()`) を `AutoPromptRules` の `templates` で上書き可能。
/// Phase 5 で `~/.config/gmux/config.toml` からロードして上書きする。
public struct AutoPromptRules: Sendable {

    public struct Templates: Sendable, Equatable {
        /// CI 失敗。`{url}` `{failingChecks}` を置換。
        public var ciFailed: String =
            "PR {url} の CI が失敗しました。失敗ジョブ: {failingChecks}\n"
            + "ログを確認して修正してください。"

        /// CHANGES_REQUESTED レビューが付いた。`{url}` `{reviewer}` `{body}` を置換。
        public var changesRequested: String =
            "PR {url} に @{reviewer} から修正リクエストが付きました。\n\n"
            + "{body}\n\nコメントを取り込んで修正をお願いします。"

        /// COMMENTED レビューが付いた。
        public var commented: String =
            "PR {url} に @{reviewer} からコメントが付きました。\n\n"
            + "{body}\n\n対応が必要なら修正してください。"

        /// main などとコンフリクトした。
        public var mergeConflict: String =
            "PR {url} がベースブランチとコンフリクトしました。解消してください。"

        public init() {}
    }

    public var templates: Templates

    public init(templates: Templates = Templates()) {
        self.templates = templates
    }

    /// `PullRequestWatcher.Event` をプロンプトに変換。
    /// 対応するルールが無い (= 何もしないべき) イベントには `nil` を返す。
    public func prompt(for event: PullRequestWatcher.Event, prURL: URL) -> String? {
        switch event {
        case .ciStateChanged(_, let to):
            switch to {
            case .failure(let failingChecks):
                return render(
                    templates.ciFailed,
                    [
                        "url": prURL.absoluteString,
                        "failingChecks": failingChecks.joined(separator: ", "),
                    ]
                )
            case .success, .pending, .noChecks:
                return nil // 成功や待ち中はプロンプト不要
            }

        case .reviewAdded(let review):
            switch review.state {
            case .changesRequested:
                return render(
                    templates.changesRequested,
                    [
                        "url": prURL.absoluteString,
                        "reviewer": review.user.login,
                        "body": review.body,
                    ]
                )
            case .commented:
                // 空コメント (state は commented だが body が無い) は無視
                guard !review.body.isEmpty else { return nil }
                return render(
                    templates.commented,
                    [
                        "url": prURL.absoluteString,
                        "reviewer": review.user.login,
                        "body": review.body,
                    ]
                )
            case .approved, .dismissed, .pending:
                return nil
            }

        case .mergeableChanged(_, let to):
            guard to == .conflicting else { return nil }
            return render(templates.mergeConflict, ["url": prURL.absoluteString])

        case .stateChanged:
            return nil // close/merge は通知のみで自動プロンプト不要
        }
    }

    /// `{key}` 形式のプレースホルダを置換する単純なレンダラ。
    /// 未指定のキーは置換せず残す (デバッグしやすくするため)。
    public static func render(_ template: String, _ values: [String: String]) -> String {
        var out = template
        for (k, v) in values {
            out = out.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return out
    }

    /// インスタンス経由でも呼べる便利関数。
    private func render(_ template: String, _ values: [String: String]) -> String {
        Self.render(template, values)
    }
}
