import Foundation

/// ペインで動く Claude セッションを表す。
///
/// 実際の PTY 書き込みは 2 つのクロージャに委譲する (Surface 非依存でテストするため):
///   - `sink`:   コマンド/プロンプト本文をペーストとして PTY に流し込む (= `Ghostty.Surface.send`)。
///   - `submit`: Enter キーを送って投入済みの行を実行確定する (= `Ghostty.Surface.sendReturn`)。
///
/// 本文に改行を付けて送るだけでは、シェルの bracketed paste mode 下でコマンドが確定しない。
/// そこで「本文をペースト → Enter で確定」の 2 段階に分け、確実に実行させる。
public final class ClaudeSession {

    /// PTY へ本文を書き込むシンク (ペースト扱い)。
    private let sink: (String) -> Void
    /// Enter キーを送って実行確定するクロージャ。
    private let submit: () -> Void

    /// 初回プロンプト投入済みか。
    public private(set) var started = false

    public init(sink: @escaping (String) -> Void, submit: @escaping () -> Void) {
        self.sink = sink
        self.submit = submit
    }

    /// Issue を起点にエージェントを起動する。`agentCommand` の `{prompt}` を
    /// シェルエスケープ済みの初回プロンプトに置換してシェルへ送る。
    /// - promptTemplate: {issue_url} {number} {title} {body} を含むプロンプト雛形。
    /// - agentCommand: 起動コマンド雛形 (例: `claude {prompt}` / `codex {prompt}`)。
    public func start(
        issue: GitHub.Issue,
        promptTemplate: String = GhmuxConfig.default.initialPrompt,
        agentCommand: String = GhmuxConfig.default.agentCommand
    ) {
        guard !started else { return }
        started = true
        let prompt = ClaudePromptBuilder.initialPrompt(for: issue, template: promptTemplate)
        let command = ClaudePromptBuilder.agentCommand(agentCommand, prompt: prompt)
        sink(command)
        submit()
    }

    /// 実行中の claude にフォローアッププロンプトを送る (自動プロンプト等)。
    /// claude の対話入力に流し込む想定なので、本文を送って Enter で確定する。
    public func send(prompt: String) {
        sink(prompt)
        submit()
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

    /// エージェント起動コマンドを組み立てる。
    /// `commandTemplate` 内の `{prompt}` をシェルエスケープ済みプロンプトに置換する。
    /// `{prompt}` が無ければ末尾にエスケープ済みプロンプトを付与する (フォールバック)。
    public static func agentCommand(_ commandTemplate: String, prompt: String) -> String {
        let quoted = shellQuote(prompt)
        if commandTemplate.contains("{prompt}") {
            return commandTemplate.replacingOccurrences(of: "{prompt}", with: quoted)
        }
        return commandTemplate + " " + quoted
    }
}
