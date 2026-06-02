import Foundation
import Testing
@testable import gmuxCore

@Suite("GmuxConfig (TOML)")
struct GmuxConfigTests {

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
        let config = try GmuxConfig.parse(toml)
        #expect(config.initialPrompt == "やること: {issue_url}")
        #expect(config.pollIntervalSeconds == 30)
        #expect(config.autoPrompts.ciFailed == "CI落ちた {url}")
        #expect(config.autoPrompts.mergeConflict == "conflict {url}")
    }

    @Test func missingKeysFallBackToDefault() throws {
        // poll_interval_seconds と auto_prompts を省略。
        let toml = #"initial_prompt = "custom""#
        let config = try GmuxConfig.parse(toml)
        #expect(config.initialPrompt == "custom")
        #expect(config.pollIntervalSeconds == GmuxConfig.default.pollIntervalSeconds)
        #expect(config.autoPrompts == GmuxConfig.default.autoPrompts)
    }

    @Test func emptyConfigIsAllDefault() throws {
        let config = try GmuxConfig.parse("")
        #expect(config == GmuxConfig.default)
    }

    @Test func multilineTomlStringPreservesNewlines() throws {
        let toml = "initial_prompt = \"\"\"\nline1\nline2\n\"\"\"\n"
        let config = try GmuxConfig.parse(toml)
        #expect(config.initialPrompt.contains("line1\nline2"))
    }

    @Test func writeDefaultThenLoadRoundTrips() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmux-test-\(UUID().uuidString)")
            .appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        // ファイル無し → デフォルト生成 + デフォルト返却。
        let created = GmuxConfig.loadOrCreateDefault(at: tmp)
        #expect(created == GmuxConfig.default)
        #expect(FileManager.default.fileExists(atPath: tmp.path))

        // 生成されたファイルを再ロードしてもデフォルトと一致する。
        let reloaded = GmuxConfig.loadOrCreateDefault(at: tmp)
        #expect(reloaded == GmuxConfig.default)
    }

    @Test func defaultFileContentsAreParseable() throws {
        let config = try GmuxConfig.parse(GmuxConfig.defaultFileContents)
        #expect(config == GmuxConfig.default)
    }

    /// 設定 UI の保存パス: encode → file → parse が値を保つ (複数行/改行込み)。
    @Test func saveThenParseRoundTrips() throws {
        let custom = GmuxConfig(
            initialPrompt: "実装して: {issue_url}\n\n{title}\n{body}",
            agentCommand: "codex exec {prompt}",
            pollIntervalSeconds: 42,
            autoPrompts: .init(
                ciFailed: "CI fail {url}\n{failingChecks}",
                changesRequested: "fix {reviewer}",
                commented: "comment {body}",
                mergeConflict: "conflict"
            )
        )
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmux-save-\(UUID().uuidString)")
            .appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        try custom.save(to: tmp)
        let reloaded = try GmuxConfig.parse(String(contentsOf: tmp, encoding: .utf8))
        #expect(reloaded == custom)
    }
}
