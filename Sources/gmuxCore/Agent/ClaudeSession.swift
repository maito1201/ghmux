import Foundation

/// ペインで動く Claude セッションを表す。
///
/// 実際の PTY 書き込みは `sink` クロージャに委譲する (= `Ghostty.Surface.send`)。
/// これによりプロンプト生成と送信ロジックを Surface 非依存でテストできる。
public final class ClaudeSession {

    /// PTY へ文字列を書き込むシンク。末尾改行は本クラスが付与する。
    private let sink: (String) -> Void

    /// 初回プロンプト投入済みか。
    public private(set) var started = false

    public init(sink: @escaping (String) -> Void) {
        self.sink = sink
    }

    /// Issue を起点に claude を起動する。シェルに `claude '<prompt>'` を送る。
    /// `promptTemplate` はプレースホルダ {issue_url} {number} {title} {body} を含む文字列。
    public func start(issue: GitHub.Issue, promptTemplate: String = GmuxConfig.default.initialPrompt) {
        guard !started else { return }
        started = true
        let prompt = ClaudePromptBuilder.initialPrompt(for: issue, template: promptTemplate)
        let command = "claude " + ClaudePromptBuilder.shellQuote(prompt)
        sink(command + "\n")
    }

    /// 実行中の claude にフォローアッププロンプトを送る (自動プロンプト等)。
    /// claude の対話入力に流し込む想定なので、プロンプトをそのまま 1 行で送る。
    public func send(prompt: String) {
        sink(prompt + "\n")
    }
}

/// プロンプト文字列の生成とシェルエスケープ (純粋ロジック)。
public enum ClaudePromptBuilder {

    /// テンプレートと Issue から初回プロンプトを組み立てる。
    /// プレースホルダ: {issue_url} {number} {title} {body}
    public static func initialPrompt(for issue: GitHub.Issue, template: String) -> String {
        AutoPromptRules.render(template, [
            "issue_url": issue.url.absoluteString,
            "number": String(issue.number),
            "title": issue.title,
            "body": issue.body,
        ])
    }

    /// シェルの単一引用符で安全に囲む。内部の ' は '\'' に置換する。
    /// 単一引用符内では改行・特殊文字をそのまま渡せる。
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
