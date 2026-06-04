import Foundation
import TOMLKit

/// ghmux のユーザー設定 (`~/.config/ghmux/config.toml`)。
///
/// 値が無いキーはデフォルトで補完する。初回起動時にデフォルト設定ファイルを書き出すので、
/// ユーザーはそれを編集して挙動を変えられる。
public struct GhmuxConfig: Codable, Equatable, Sendable {

    /// Issue URL を貼ったときにエージェントへ渡す初回プロンプトのテンプレート。
    /// 使えるプレースホルダ: `{issue_url}` `{number}` `{title}` `{body}`
    public var initialPrompt: String

    /// エージェントを起動するシェルコマンドのテンプレート。
    /// `{prompt}` が初回プロンプト (シェルエスケープ済み) に置換される。
    /// 例: `claude {prompt}` / `codex {prompt}` / `codex exec {prompt}`
    public var agentCommand: String

    /// PR / CI のポーリング間隔 (秒)。
    public var pollIntervalSeconds: Int

    /// PR 状態変化時の自動プロンプト。
    public var autoPrompts: AutoPrompts

    public struct AutoPrompts: Codable, Equatable, Sendable {
        public var ciFailed: String
        public var changesRequested: String
        public var commented: String
        public var mergeConflict: String

        enum CodingKeys: String, CodingKey {
            case ciFailed = "ci_failed"
            case changesRequested = "changes_requested"
            case commented
            case mergeConflict = "merge_conflict"
        }
    }

    enum CodingKeys: String, CodingKey {
        case initialPrompt = "initial_prompt"
        case agentCommand = "agent_command"
        case pollIntervalSeconds = "poll_interval_seconds"
        case autoPrompts = "auto_prompts"
    }

    // MARK: - デコード (欠落キーはデフォルト補完)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = GhmuxConfig.default
        self.initialPrompt = (try c.decodeIfPresent(String.self, forKey: .initialPrompt)) ?? def.initialPrompt
        self.agentCommand = (try c.decodeIfPresent(String.self, forKey: .agentCommand)) ?? def.agentCommand
        self.pollIntervalSeconds = (try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds)) ?? def.pollIntervalSeconds
        self.autoPrompts = (try c.decodeIfPresent(AutoPrompts.self, forKey: .autoPrompts)) ?? def.autoPrompts
    }

    public init(
        initialPrompt: String,
        agentCommand: String,
        pollIntervalSeconds: Int,
        autoPrompts: AutoPrompts
    ) {
        self.initialPrompt = initialPrompt
        self.agentCommand = agentCommand
        self.pollIntervalSeconds = pollIntervalSeconds
        self.autoPrompts = autoPrompts
    }

    // MARK: - デフォルト

    public static let `default` = GhmuxConfig(
        initialPrompt: """
            GitHub Issue {issue_url} に取り組んでください。実装が完了したら、この Issue を closes するプルリクエストを作成してください。

            # {title}

            {body}
            """,
        agentCommand: "claude {prompt}",
        pollIntervalSeconds: 15,
        autoPrompts: AutoPrompts(
            ciFailed: "PR {url} の CI が失敗しました。失敗ジョブ: {failingChecks}\nログを確認して修正してください。",
            changesRequested: "PR {url} に @{reviewer} から修正リクエストが付きました。\n\n{body}\n\nコメントを取り込んで修正をお願いします。",
            commented: "PR {url} に @{reviewer} からコメントが付きました。\n\n{body}\n\n対応が必要なら修正してください。",
            mergeConflict: "PR {url} がベースブランチとコンフリクトしました。解消してください。"
        )
    )

    // MARK: - ロード

    /// `~/.config/ghmux/config.toml`。
    public static var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/ghmux/config.toml")
    }

    /// アプリ起動中にキャッシュした現在の設定。初回アクセス時にロードする。
    nonisolated(unsafe) private static var cached: GhmuxConfig?
    public static var current: GhmuxConfig {
        if let cached { return cached }
        let c = loadOrCreateDefault()
        cached = c
        return c
    }

    /// 設定をロードする。ファイルが無ければデフォルトを書き出してデフォルトを返す。
    /// パースに失敗した場合はデフォルトにフォールバックする (アプリは止めない)。
    public static func loadOrCreateDefault(at url: URL = GhmuxConfig.defaultURL) -> GhmuxConfig {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? writeDefaultFile(to: url)
            return .default
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            return try parse(text)
        } catch {
            return .default
        }
    }

    /// TOML 文字列をパースする。
    public static func parse(_ toml: String) throws -> GhmuxConfig {
        try TOMLDecoder().decode(GhmuxConfig.self, from: toml)
    }

    /// 設定を TOML として書き出し、キャッシュも更新する (設定 UI から呼ぶ)。
    /// 即時反映は「以後に作られるペイン / セッション」に効く。
    public func save(to url: URL = GhmuxConfig.defaultURL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let toml = try TOMLEncoder().encode(self)
        try toml.write(to: url, atomically: true, encoding: .utf8)
        GhmuxConfig.cached = self
    }

    /// 注釈付きのデフォルト設定ファイルを書き出す。
    public static func writeDefaultFile(to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.defaultFileContents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 初回生成するコメント付き TOML。手編集の出発点。
    static let defaultFileContents = """
        # ghmux 設定ファイル
        # 変更は次回 ghmux 起動時に反映されます。

        # Issue の URL を貼ったときにエージェントへ渡す初回プロンプト。
        # 使えるプレースホルダ: {issue_url} {number} {title} {body}
        # (末尾の \\ は改行を含めないための TOML 記法)
        initial_prompt = \"\"\"
        GitHub Issue {issue_url} に取り組んでください。実装が完了したら、この Issue を closes するプルリクエストを作成してください。

        # {title}

        {body}\\
        \"\"\"

        # エージェントを起動するコマンド。{prompt} が初回プロンプト(エスケープ済み)に置換される。
        # 例: "claude {prompt}" / "codex {prompt}" / "codex exec {prompt}"
        agent_command = "claude {prompt}"

        # PR / CI のポーリング間隔（秒）
        poll_interval_seconds = 15

        # PR の状態変化時に claude へ自動送信するプロンプト。
        # ci_failed / commented で使えるプレースホルダ: {url} {failingChecks} {reviewer} {body}
        [auto_prompts]
        ci_failed = "PR {url} の CI が失敗しました。失敗ジョブ: {failingChecks}\\nログを確認して修正してください。"
        changes_requested = "PR {url} に @{reviewer} から修正リクエストが付きました。\\n\\n{body}\\n\\nコメントを取り込んで修正をお願いします。"
        commented = "PR {url} に @{reviewer} からコメントが付きました。\\n\\n{body}\\n\\n対応が必要なら修正してください。"
        merge_conflict = "PR {url} がベースブランチとコンフリクトしました。解消してください。"
        """
}
