import Foundation
import Testing
@testable import gmuxCore

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
        let session = ClaudeSession(sink: { sent.append($0) })
        session.start(issue: makeIssue())
        session.start(issue: makeIssue()) // 2 回目は無視
        #expect(sent.count == 1)
        #expect(sent[0].hasPrefix("claude '"))
        #expect(sent[0].hasSuffix("'\n"))
        #expect(sent[0].contains("issues/42"))
        #expect(session.started)
    }

    @Test func followUpPromptAppendsNewline() {
        var sent: [String] = []
        let session = ClaudeSession(sink: { sent.append($0) })
        session.send(prompt: "CI が失敗しました")
        #expect(sent == ["CI が失敗しました\n"])
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
        let prompt = ClaudePromptBuilder.initialPrompt(for: makeIssue(title: "Add X", body: "Do Y"))
        #expect(prompt.contains("issues/42"))
        #expect(prompt.contains("Add X"))
        #expect(prompt.contains("Do Y"))
    }
}
