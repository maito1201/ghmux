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
    /// `prs` は (number, state) のリスト。リポジトリは acme/widgets 既定。
    private func graphql(prs: [(Int, String)], repo: String = "acme/widgets") -> Data {
        let nodes = prs.map { (num, state) in
            "{\"__typename\":\"CrossReferencedEvent\",\"source\":{\"__typename\":\"PullRequest\",\"url\":\"https://github.com/\(repo)/pull/\(num)\",\"number\":\(num),\"state\":\"\(state)\"}}"
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

    @Test func linkedURLPicksLastActive() async throws {
        // timeline 順で最後に参照された OPEN/MERGED を採用 (= 30)。
        let runner = SequencedRunner([graphql(prs: [(12, "OPEN"), (99, "MERGED"), (30, "OPEN")])])
        let client = GitHubClient(runner: runner)
        let url = try await client.linkedPullRequestURL(owner: "acme", repo: "widgets", issueNumber: 42)
        #expect(url?.absoluteString == "https://github.com/acme/widgets/pull/30")
        #expect(runner.allArgs.first?.contains("graphql") == true)
    }

    @Test func linkedURLSkipsClosedUnmerged() async throws {
        // 最後の参照が CLOSED(未マージ)なら、その前の OPEN を優先。
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
