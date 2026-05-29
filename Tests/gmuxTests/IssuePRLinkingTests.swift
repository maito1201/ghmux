import Foundation
import Testing
@testable import gmuxCore

@Suite("Issue ↔ PR linking")
struct IssuePRLinkingTests {

    final class FixtureRunner: GitHubClient.Runner, @unchecked Sendable {
        let data: Data
        private(set) var lastArgs: [String] = []
        let lock = NSLock()
        init(_ data: Data) { self.data = data }
        func run(arguments: [String]) async throws -> Data {
            lock.lock(); lastArgs = arguments; lock.unlock()
            return data
        }
    }

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            struct E: Error { let n: String }; throw E(n: name)
        }
        return try Data(contentsOf: url)
    }

    // MARK: - URL parsing

    @Test func parseIssueUrl() throws {
        let r = try GitHubClient.parseIssueUrl(URL(string: "https://github.com/acme/widgets/issues/42")!)
        #expect(r.owner == "acme")
        #expect(r.repo == "widgets")
        #expect(r.number == 42)
    }

    @Test func parseIssueUrlRejectsPR() {
        #expect(throws: GitHubClient.Error.self) {
            _ = try GitHubClient.parseIssueUrl(URL(string: "https://github.com/acme/widgets/pull/42")!)
        }
    }

    // MARK: - reference matching (word boundary)

    @Test func referencesExactIssueNumber() throws {
        let prs = try JSONDecoder().decode([GitHub.PullRequest].self, from: fixtureData("pr-list"))
        let pr99 = prs.first { $0.number == 99 }!
        let pr87 = prs.first { $0.number == 87 }!
        #expect(GitHubClient.references(issueNumber: 42, in: pr99))   // "Closes #42"
        #expect(!GitHubClient.references(issueNumber: 42, in: pr87))  // "#421" は #42 にマッチしない
        #expect(GitHubClient.references(issueNumber: 421, in: pr87))
    }

    // MARK: - finder

    @Test func findPullRequestForIssue() async throws {
        let runner = FixtureRunner(try fixtureData("pr-list"))
        let client = GitHubClient(runner: runner)
        let pr = try await client.findPullRequest(forIssueNumber: 42, owner: "acme", repo: "widgets")
        #expect(pr?.number == 99)
        // gh pr list が正しい引数で呼ばれていること
        #expect(runner.lastArgs.contains("list"))
        #expect(runner.lastArgs.contains("acme/widgets"))
    }

    @Test func findPullRequestReturnsNilWhenNoMatch() async throws {
        let runner = FixtureRunner(try fixtureData("pr-list"))
        let client = GitHubClient(runner: runner)
        let pr = try await client.findPullRequest(forIssueNumber: 999, owner: "acme", repo: "widgets")
        #expect(pr == nil)
    }
}
