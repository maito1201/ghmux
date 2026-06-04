import Foundation
import Testing
@testable import ghmuxCore

@Suite("AutoPromptRules")
struct AutoPromptRulesTests {

    private let prURL = URL(string: "https://github.com/acme/widgets/pull/99")!

    @Test func ciFailureProducesPrompt() {
        let rules = AutoPromptRules()
        let event = PullRequestWatcher.Event.ciStateChanged(
            from: .success, to: .failure(failingChecks: ["test", "lint"])
        )
        let prompt = rules.prompt(for: event, prURL: prURL)
        #expect(prompt?.contains("https://github.com/acme/widgets/pull/99") == true)
        #expect(prompt?.contains("test, lint") == true)
    }

    @Test func ciSuccessReturnsNil() {
        let rules = AutoPromptRules()
        let event = PullRequestWatcher.Event.ciStateChanged(from: .pending, to: .success)
        #expect(rules.prompt(for: event, prURL: prURL) == nil)
    }

    @Test func changesRequestedReviewProducesPrompt() {
        let rules = AutoPromptRules()
        let review = GitHub.Review(
            id: 1, user: .init(login: "carol"),
            state: .changesRequested,
            body: "Please add tests.",
            submittedAt: nil
        )
        let prompt = rules.prompt(for: .reviewAdded(review), prURL: prURL)
        #expect(prompt?.contains("@carol") == true)
        #expect(prompt?.contains("Please add tests.") == true)
    }

    @Test func approvedReviewReturnsNil() {
        let rules = AutoPromptRules()
        let review = GitHub.Review(
            id: 1, user: .init(login: "bob"),
            state: .approved, body: "lgtm", submittedAt: nil
        )
        #expect(rules.prompt(for: .reviewAdded(review), prURL: prURL) == nil)
    }

    @Test func emptyCommentReviewReturnsNil() {
        let rules = AutoPromptRules()
        let review = GitHub.Review(
            id: 1, user: .init(login: "bob"),
            state: .commented, body: "", submittedAt: nil
        )
        #expect(rules.prompt(for: .reviewAdded(review), prURL: prURL) == nil)
    }

    @Test func mergeConflictProducesPrompt() {
        let rules = AutoPromptRules()
        let event = PullRequestWatcher.Event.mergeableChanged(from: .mergeable, to: .conflicting)
        let prompt = rules.prompt(for: event, prURL: prURL)
        #expect(prompt?.contains("コンフリクト") == true)
    }

    @Test func mergeableTransitionsBackToMergeableReturnsNil() {
        let rules = AutoPromptRules()
        let event = PullRequestWatcher.Event.mergeableChanged(from: .conflicting, to: .mergeable)
        #expect(rules.prompt(for: event, prURL: prURL) == nil)
    }

    @Test func mergedStateReturnsNil() {
        let rules = AutoPromptRules()
        let event = PullRequestWatcher.Event.stateChanged(from: .open, to: .merged)
        #expect(rules.prompt(for: event, prURL: prURL) == nil)
    }

    @Test func customTemplatesAreUsed() {
        var templates = AutoPromptRules.Templates()
        templates.ciFailed = "❌ CI {url} → {failingChecks}"
        let rules = AutoPromptRules(templates: templates)

        let event = PullRequestWatcher.Event.ciStateChanged(
            from: .success, to: .failure(failingChecks: ["x"])
        )
        let prompt = rules.prompt(for: event, prURL: prURL)
        #expect(prompt == "❌ CI https://github.com/acme/widgets/pull/99 → x")
    }

    @Test func renderLeavesUnknownPlaceholders() {
        let out = AutoPromptRules.render("Hello {name}, age {age}", ["name": "alice"])
        #expect(out == "Hello alice, age {age}")
    }
}
