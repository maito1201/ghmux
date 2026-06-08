import Foundation
import Testing
@testable import ghmuxCore

@Suite("Issue ↔ PR linking (GraphQL)")
struct IssuePRLinkingTests {

    /// 呼び出しごとにキュー先頭の Data を返す Runner。
    final class SequencedRunner: GitHubClient.Runner, @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [Data]
        private(set) var allArgs: [[String]] = []
        init(_ queue: [Data]) { self.queue = queue }
        func run(arguments: [String]) async throws -> Data {
            lock.lock(); defer { lock.unlock() }
            allArgs.append(arguments)
            return queue.isEmpty ? Data("{}".utf8) : queue.removeFirst()
        }
    }

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            struct E: Error { let n: String }; throw E(n: name)
        }
        return try Data(contentsOf: url)
    }

    /// timelineItems の CrossReferencedEvent 形状を組み立てる。
    /// `prs` は (number, state) のリスト。createdAt は timeline 順 (配列順) に増加させる。
    /// リポジトリは acme/widgets 既定。
    private func graphql(prs: [(Int, String)], repo: String = "acme/widgets") -> Data {
        let dated = prs.enumerated().map { (i, pr) in
            (pr.0, pr.1, "2024-01-01T00:\(String(format: "%02d", i)):00Z")
        }
        return graphqlDated(prs: dated, repo: repo)
    }

    /// createdAt を明示する版 (作成日時と timeline 順が食い違うケースの検証用)。
    /// `prs` は (number, state, createdAt[ISO8601]) のリスト。
    private func graphqlDated(prs: [(Int, String, String)], repo: String = "acme/widgets") -> Data {
        let nodes = prs.map { (num, state, createdAt) in
            "{\"__typename\":\"CrossReferencedEvent\",\"source\":{\"__typename\":\"PullRequest\",\"url\":\"https://github.com/\(repo)/pull/\(num)\",\"number\":\(num),\"state\":\"\(state)\",\"createdAt\":\"\(createdAt)\"}}"
        }.joined(separator: ",")
        let json = "{\"data\":{\"repository\":{\"issue\":{\"timelineItems\":{\"nodes\":[\(nodes)]}}}}}"
        return Data(json.utf8)
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

    // MARK: - linkedPullRequestURL (GraphQL)

    @Test func linkedURLPicksNewestActive() async throws {
        // createdAt が最新の OPEN/MERGED を採用 (= 30)。
        let runner = SequencedRunner([graphql(prs: [(12, "OPEN"), (99, "MERGED"), (30, "OPEN")])])
        let client = GitHubClient(runner: runner)
        let url = try await client.linkedPullRequestURL(owner: "acme", repo: "widgets", issueNumber: 42)
        #expect(url?.absoluteString == "https://github.com/acme/widgets/pull/30")
        #expect(runner.allArgs.first?.contains("graphql") == true)
    }

    @Test func linkedURLPicksNewestNotLastReferenced() async throws {
        // バグ再現: 古い PR (#12) が timeline 末尾に再参照されても、
        // createdAt が新しい #30 を採用する (参照順ではなく作成日時で選ぶ)。
        let runner = SequencedRunner([graphqlDated(prs: [
            (30, "OPEN", "2024-02-01T00:00:00Z"),
            (12, "OPEN", "2024-01-01T00:00:00Z"),
        ])])
        let client = GitHubClient(runner: runner)
        let url = try await client.linkedPullRequestURL(owner: "acme", repo: "widgets", issueNumber: 42)
        #expect(url?.absoluteString == "https://github.com/acme/widgets/pull/30")
    }

    @Test func linkedURLSkipsClosedUnmerged() async throws {
        // CLOSED(未マージ)は後回し。OPEN を優先。
        let runner = SequencedRunner([graphql(prs: [(50, "OPEN"), (51, "CLOSED")])])
        let client = GitHubClient(runner: runner)
        let url = try await client.linkedPullRequestURL(owner: "acme", repo: "widgets", issueNumber: 42)
        #expect(url?.absoluteString == "https://github.com/acme/widgets/pull/50")
    }

    @Test func linkedURLAcceptsCrossRepoPR() async throws {
        // Issue と別リポの PR も拾えること (notahotel ケース)。
        let runner = SequencedRunner([graphql(prs: [(14740, "OPEN")], repo: "notahotel/notahotel-api")])
        let client = GitHubClient(runner: runner)
        let url = try await client.linkedPullRequestURL(owner: "notahotel", repo: "notahotel", issueNumber: 10398)
        #expect(url?.absoluteString == "https://github.com/notahotel/notahotel-api/pull/14740")
    }

    @Test func linkedURLNilWhenNoNodes() async throws {
        let runner = SequencedRunner([graphql(prs: [])])
        let client = GitHubClient(runner: runner)
        let url = try await client.linkedPullRequestURL(owner: "acme", repo: "widgets", issueNumber: 42)
        #expect(url == nil)
    }

    // MARK: - linkedPullRequestURLs (1 Issue : N PR)

    @Test func linkedURLsReturnsAllSortedByCreatedAt() async throws {
        // 全 PR を作成日時昇順で返す (CLOSED も含む)。
        let runner = SequencedRunner([graphqlDated(prs: [
            (30, "OPEN", "2024-02-01T00:00:00Z"),
            (12, "CLOSED", "2024-01-01T00:00:00Z"),
            (45, "MERGED", "2024-03-01T00:00:00Z"),
        ])])
        let client = GitHubClient(runner: runner)
        let urls = try await client.linkedPullRequestURLs(owner: "acme", repo: "widgets", issueNumber: 42)
        #expect(urls.map(\.absoluteString) == [
            "https://github.com/acme/widgets/pull/12",
            "https://github.com/acme/widgets/pull/30",
            "https://github.com/acme/widgets/pull/45",
        ])
    }

    @Test func linkedURLsDeduplicatesRepeatedReferences() async throws {
        // 同一 PR が timeline で複数回参照されても 1 件に畳む。
        let runner = SequencedRunner([graphql(prs: [(7, "OPEN"), (7, "OPEN"), (8, "OPEN")])])
        let client = GitHubClient(runner: runner)
        let urls = try await client.linkedPullRequestURLs(owner: "acme", repo: "widgets", issueNumber: 42)
        #expect(urls.map(\.absoluteString) == [
            "https://github.com/acme/widgets/pull/7",
            "https://github.com/acme/widgets/pull/8",
        ])
    }

    @Test func linkedURLsEmptyWhenNoNodes() async throws {
        let runner = SequencedRunner([graphql(prs: [])])
        let client = GitHubClient(runner: runner)
        let urls = try await client.linkedPullRequestURLs(owner: "acme", repo: "widgets", issueNumber: 42)
        #expect(urls.isEmpty)
    }

    @Test func findPullRequestsResolvesAll() async throws {
        // graphql で 2 件 → 各 PR 詳細を解決して配列で返す。
        let runner = SequencedRunner([
            graphql(prs: [(99, "OPEN"), (100, "OPEN")]),
            try fixtureData("pr-success"),
            try fixtureData("pr-failure"),
        ])
        let client = GitHubClient(runner: runner)
        let prs = try await client.findPullRequests(forIssueNumber: 42, owner: "acme", repo: "widgets")
        #expect(prs.count == 2)
    }

    // MARK: - findPullRequest (GraphQL → PR 詳細)

    @Test func findPullRequestResolvesViaGraphQL() async throws {
        // 1 回目: graphql で linked PR (#99)、2 回目: その PR の詳細 (pr-success)。
        let runner = SequencedRunner([
            graphql(prs: [(99, "OPEN")]),
            try fixtureData("pr-success"),
        ])
        let client = GitHubClient(runner: runner)
        let pr = try await client.findPullRequest(forIssueNumber: 42, owner: "acme", repo: "widgets")
        #expect(pr?.number == 99)
        #expect(pr?.mergeable == .mergeable)
    }

    @Test func findPullRequestNilWhenNoLinkedPR() async throws {
        let runner = SequencedRunner([graphql(prs: [])])
        let client = GitHubClient(runner: runner)
        let pr = try await client.findPullRequest(forIssueNumber: 42, owner: "acme", repo: "widgets")
        #expect(pr == nil)
    }
}
