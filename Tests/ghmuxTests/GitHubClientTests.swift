import Foundation
import Testing
@testable import ghmuxCore

@Suite("GitHubClient with mock runner")
struct GitHubClientTests {

    /// fixture を返すだけのモック。受け取った引数も検査用に保持する。
    final class MockRunner: GitHubClient.Runner, @unchecked Sendable {
        private let lock = NSLock()
        private var fixture: Data
        private var argumentsHistory: [[String]] = []

        init(fixture: Data) { self.fixture = fixture }

        func run(arguments: [String]) async throws -> Data {
            lock.lock(); defer { lock.unlock() }
            argumentsHistory.append(arguments)
            return fixture
        }

        func setFixture(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            fixture = data
        }

        func capturedArguments() -> [[String]] {
            lock.lock(); defer { lock.unlock() }
            return argumentsHistory
        }
    }

    @Test func fetchIssueInvokesGhAndDecodes() async throws {
        let data = try fixtureData("issue")
        let runner = MockRunner(fixture: data)
        let client = GitHubClient(runner: runner)

        let url = URL(string: "https://github.com/acme/widgets/issues/42")!
        let issue = try await client.fetchIssue(url: url)

        #expect(issue.number == 42)
        #expect(issue.title == "Add dark mode")

        let calls = runner.capturedArguments()
        #expect(calls.count == 1)
        #expect(calls[0].first == "issue")
        #expect(calls[0].contains("view"))
        #expect(calls[0].contains(url.absoluteString))
        #expect(calls[0].contains("--json"))
    }

    @Test func fetchPullRequestDecodesRollup() async throws {
        let data = try fixtureData("pr-failure")
        let runner = MockRunner(fixture: data)
        let client = GitHubClient(runner: runner)

        let pr = try await client.fetchPullRequest(
            url: URL(string: "https://github.com/acme/widgets/pull/100")!
        )
        #expect(pr.number == 100)
        #expect(pr.mergeable == .conflicting)
        #expect(pr.statusCheckRollup?.count == 2)
    }

    @Test func fetchAssignedOpenIssuesDecodesListAndQueriesAssignee() async throws {
        let data = try fixtureData("issues-list")
        let runner = MockRunner(fixture: data)
        let client = GitHubClient(runner: runner)

        let issues = try await client.fetchAssignedOpenIssues(repo: "acme/widgets")
        #expect(issues.count == 2)
        #expect(issues[0].number == 42)
        #expect(issues[1].title == "Fix flaky login test")

        let calls = runner.capturedArguments()
        #expect(calls.count == 1)
        #expect(calls[0].first == "issue")
        #expect(calls[0].contains("list"))
        #expect(calls[0].contains("--repo"))
        #expect(calls[0].contains("acme/widgets"))
        #expect(calls[0].contains("--assignee"))
        #expect(calls[0].contains("@me"))
        #expect(calls[0].contains("--state"))
        #expect(calls[0].contains("open"))
    }

    @Test func fetchReviewsHitsApiEndpoint() async throws {
        let data = try fixtureData("reviews")
        let runner = MockRunner(fixture: data)
        let client = GitHubClient(runner: runner)

        let reviews = try await client.fetchReviews(
            prURL: URL(string: "https://github.com/acme/widgets/pull/100")!
        )
        #expect(reviews.count == 2)

        let calls = runner.capturedArguments()
        #expect(calls.count == 1)
        #expect(calls[0] == ["api", "repos/acme/widgets/pulls/100/reviews"])
    }

    @Test func decodeErrorIsSurfaced() async throws {
        let bogus = Data("not json".utf8)
        let runner = MockRunner(fixture: bogus)
        let client = GitHubClient(runner: runner)

        await #expect(throws: GitHubClient.Error.self) {
            _ = try await client.fetchIssue(
                url: URL(string: "https://github.com/x/y/issues/1")!
            )
        }
    }

    // MARK: - fixture loader

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ) else {
            struct E: Error { let name: String }
            throw E(name: name)
        }
        return try Data(contentsOf: url)
    }
}
