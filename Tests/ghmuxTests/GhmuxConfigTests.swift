import Foundation
import Testing
@testable import ghmuxCore

@Suite("GhmuxConfig (TOML)")
struct GhmuxConfigTests {

    @Test func parsesFullConfig() throws {
        let toml = """
            initial_prompt = "やること: {issue_url}"
            poll_interval_seconds = 30

            [auto_prompts]
            ci_failed = "CI落ちた {url}"
            changes_requested = "直して {reviewer}"
            commented = "コメント {body}"
            merge_conflict = "conflict {url}"
            """
        let config = try GhmuxConfig.parse(toml)
        #expect(config.initialPrompt == "やること: {issue_url}")
        #expect(config.pollIntervalSeconds == 30)
        #expect(config.autoPrompts.ciFailed == "CI落ちた {url}")
        #expect(config.autoPrompts.mergeConflict == "conflict {url}")
        // ci_passed を含まない既存設定でも、他キーは保持し ci_passed のみデフォルト補完する
        // (auto_prompts 全体がデフォルトへ巻き戻らないことの後方互換検証)。
        #expect(config.autoPrompts.changesRequested == "直して {reviewer}")
        #expect(config.autoPrompts.ciPassed == GhmuxConfig.default.autoPrompts.ciPassed)
    }

    @Test func missingKeysFallBackToDefault() throws {
        // poll_interval_seconds と auto_prompts を省略。
        let toml = #"initial_prompt = "custom""#
        let config = try GhmuxConfig.parse(toml)
        #expect(config.initialPrompt == "custom")
        #expect(config.pollIntervalSeconds == GhmuxConfig.default.pollIntervalSeconds)
        #expect(config.autoPrompts == GhmuxConfig.default.autoPrompts)
    }

    @Test func parsesPrInitialPrompt() throws {
        let toml = #"pr_initial_prompt = "PR を見て {pr_url}""#
        let config = try GhmuxConfig.parse(toml)
        #expect(config.prInitialPrompt == "PR を見て {pr_url}")
    }

    @Test func missingPrInitialPromptFallsBackToDefault() throws {
        let config = try GhmuxConfig.parse(#"initial_prompt = "x""#)
        #expect(config.prInitialPrompt == GhmuxConfig.default.prInitialPrompt)
    }

    @Test func parsesIssuesRepositories() throws {
        let toml = """
            [issues]
            repositories = [
              "acme/widgets",
              "acme/api",
            ]
            """
        let config = try GhmuxConfig.parse(toml)
        #expect(config.issues.repositories == ["acme/widgets", "acme/api"])
    }

    @Test func missingIssuesSectionDefaultsToEmpty() throws {
        let config = try GhmuxConfig.parse(#"initial_prompt = "custom""#)
        #expect(config.issues.repositories.isEmpty)
        #expect(config.issues == GhmuxConfig.default.issues)
    }

    @Test func emptyConfigIsAllDefault() throws {
        let config = try GhmuxConfig.parse("")
        #expect(config == GhmuxConfig.default)
    }

    @Test func multilineTomlStringPreservesNewlines() throws {
        let toml = "initial_prompt = \"\"\"\nline1\nline2\n\"\"\"\n"
        let config = try GhmuxConfig.parse(toml)
        #expect(config.initialPrompt.contains("line1\nline2"))
    }

    @Test func writeDefaultThenLoadRoundTrips() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghmux-test-\(UUID().uuidString)")
            .appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        // ファイル無し → デフォルト生成 + デフォルト返却。
        let created = GhmuxConfig.loadOrCreateDefault(at: tmp)
        #expect(created == GhmuxConfig.default)
        #expect(FileManager.default.fileExists(atPath: tmp.path))

        // 生成されたファイルを再ロードしてもデフォルトと一致する。
        let reloaded = GhmuxConfig.loadOrCreateDefault(at: tmp)
        #expect(reloaded == GhmuxConfig.default)
    }

    @Test func defaultFileContentsAreParseable() throws {
        let config = try GhmuxConfig.parse(GhmuxConfig.defaultFileContents)
        #expect(config == GhmuxConfig.default)
    }

    /// 設定 UI の保存パス: encode → file → parse が値を保つ (複数行/改行込み)。
    @Test func saveThenParseRoundTrips() throws {
        let custom = GhmuxConfig(
            initialPrompt: "実装して: {issue_url}\n\n{title}\n{body}",
            prInitialPrompt: "PR 見て: {pr_url}\n\n{title}\n{body}",
            agentCommand: "codex exec {prompt}",
            pollIntervalSeconds: 42,
            autoPrompts: .init(
                ciFailed: "CI fail {url}\n{failingChecks}",
                ciPassed: "CI pass {url}",
                changesRequested: "fix {reviewer}",
                commented: "comment {body}",
                mergeConflict: "conflict"
            ),
            issues: .init(repositories: ["acme/widgets", "acme/api"])
        )
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghmux-save-\(UUID().uuidString)")
            .appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        try custom.save(to: tmp)
        let reloaded = try GhmuxConfig.parse(String(contentsOf: tmp, encoding: .utf8))
        #expect(reloaded == custom)
    }
}
