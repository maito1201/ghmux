import Foundation
import Testing
@testable import ghmuxCore

@Suite("ClaudeSession / PromptBuilder")
struct ClaudeSessionTests {

    private func makeIssue(title: String = "Add dark mode", body: String = "Toggle in prefs.") -> GitHub.Issue {
        GitHub.Issue(
            number: 42,
            title: title,
            body: body,
            url: URL(string: "https://github.com/acme/widgets/issues/42")!,
            state: .open,
            author: .init(login: "alice"),
            labels: []
        )
    }

    @Test func startSendsClaudeCommandOnce() {
        var sent: [String] = []
        var submits = 0
        let session = ClaudeSession(sink: { sent.append($0) }, submit: { submits += 1 })
        session.start(issue: makeIssue())
        session.start(issue: makeIssue()) // 2 回目は無視
        #expect(sent.count == 1)
        #expect(submits == 1) // 本文投入後に Enter で 1 回確定する
        #expect(sent[0].hasPrefix("claude '"))
        #expect(sent[0].hasSuffix("'")) // 改行は付けず、確定は submit() に委ねる
        #expect(sent[0].contains("issues/42"))
        #expect(session.started)
    }

    @Test func startUsesCustomAgentCommand() {
        var sent: [String] = []
        var submits = 0
        let session = ClaudeSession(sink: { sent.append($0) }, submit: { submits += 1 })
        session.start(issue: makeIssue(), agentCommand: "codex exec {prompt}")
        #expect(sent.count == 1)
        #expect(submits == 1)
        #expect(sent[0].hasPrefix("codex exec '"))
        #expect(sent[0].contains("issues/42"))
        #expect(sent[0].hasSuffix("'"))
    }

    @Test func agentCommandSubstitutesPromptPlaceholder() {
        let cmd = ClaudePromptBuilder.agentCommand("codex {prompt}", prompt: "do it")
        #expect(cmd == "codex 'do it'")
    }

    @Test func agentCommandAppendsWhenNoPlaceholder() {
        let cmd = ClaudePromptBuilder.agentCommand("claude", prompt: "do it")
        #expect(cmd == "claude 'do it'")
    }

    @Test func followUpPromptSendsBodyThenSubmits() {
        var sent: [String] = []
        var submits = 0
        let session = ClaudeSession(sink: { sent.append($0) }, submit: { submits += 1 })
        session.send(prompt: "CI が失敗しました")
        #expect(sent == ["CI が失敗しました"]) // 本文のみ。改行は付けない
        #expect(submits == 1) // Enter で確定
    }

    @Test func shellQuoteEscapesSingleQuotes() {
        let quoted = ClaudePromptBuilder.shellQuote("it's a test")
        #expect(quoted == "'it'\\''s a test'")
    }

    @Test func shellQuotePreservesNewlines() {
        let quoted = ClaudePromptBuilder.shellQuote("line1\nline2")
        #expect(quoted == "'line1\nline2'")
    }

    @Test func initialPromptContainsIssueDetails() {
        let prompt = ClaudePromptBuilder.initialPrompt(
            for: makeIssue(title: "Add X", body: "Do Y"),
            template: GhmuxConfig.default.initialPrompt
        )
        #expect(prompt.contains("issues/42"))
        #expect(prompt.contains("Add X"))
        #expect(prompt.contains("Do Y"))
    }

    @Test func initialPromptUsesCustomTemplatePlaceholders() {
        let prompt = ClaudePromptBuilder.initialPrompt(
            for: makeIssue(title: "T", body: "B"),
            template: "#{number} {title} :: {body} @ {issue_url}"
        )
        #expect(prompt == "#42 T :: B @ https://github.com/acme/widgets/issues/42")
    }
}
