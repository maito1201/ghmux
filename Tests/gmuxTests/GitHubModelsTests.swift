import Foundation
import Testing
@testable import gmuxCore

@Suite("GitHub.Models")
struct GitHubModelsTests {

    // MARK: - 寛容デコード (実データ回帰)

    /// gh は未完了チェックで conclusion に空文字 "" を返す。以前これで dataCorrupted になった。
    @Test func decodesEmptyConclusionAndUnknownStatus() throws {
        let json = """
        {
          "number": 1, "title": "t", "url": "https://github.com/a/b/pull/1",
          "state": "OPEN", "isDraft": false, "headRefName": "f", "baseRefName": "main",
          "mergeable": "MERGEABLE",
          "statusCheckRollup": [
            {"name":"build","workflowName":"CI","status":"IN_PROGRESS","conclusion":"","detailsUrl":"https://x/1"},
            {"name":"lint","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":""},
            {"name":"odd","workflowName":"CI","status":"WEIRD_STATUS","conclusion":"SKIPPED","detailsUrl":null}
          ]
        }
        """
        let pr = try JSONDecoder().decode(GitHub.PullRequest.self, from: Data(json.utf8))
        let checks = pr.statusCheckRollup ?? []
        #expect(checks.count == 3)
        // 空 conclusion は nil、未知 status は .unknown、空 URL は nil に倒れる。
        #expect(checks[0].conclusion == nil)
        #expect(checks[0].status == .inProgress)
        #expect(checks[1].detailsUrl == nil)
        #expect(checks[2].status == .unknown)
        // IN_PROGRESS が残るので pending。
        #expect(GitHub.CIStatus.roll(checks) == .pending)
    }

    // MARK: - Decoding

    @Test func decodeIssueFixture() throws {
        let issue = try decode(GitHub.Issue.self, fixture: "issue")
        #expect(issue.number == 42)
        #expect(issue.title == "Add dark mode")
        #expect(issue.state == .open)
        #expect(issue.author?.login == "alice")
        #expect(issue.labels.map(\.name) == ["enhancement", "good first issue"])
        #expect(issue.url.absoluteString == "https://github.com/acme/widgets/issues/42")
    }

    @Test func decodePRSuccessFixture() throws {
        let pr = try decode(GitHub.PullRequest.self, fixture: "pr-success")
        #expect(pr.number == 99)
        #expect(pr.state == .open)
        #expect(pr.isDraft == false)
        #expect(pr.mergeable == .mergeable)
        #expect(pr.statusCheckRollup?.count == 2)
    }

    @Test func decodePRFailureFixture() throws {
        let pr = try decode(GitHub.PullRequest.self, fixture: "pr-failure")
        #expect(pr.isDraft)
        #expect(pr.mergeable == .conflicting)
        let lint = pr.statusCheckRollup?.first(where: { $0.name == "lint" })
        #expect(lint?.status == .inProgress)
        #expect(lint?.conclusion == nil)
    }

    @Test func decodeReviewsFixture() throws {
        let reviews = try decode([GitHub.Review].self, fixture: "reviews")
        #expect(reviews.count == 2)
        #expect(reviews[0].state == .approved)
        #expect(reviews[1].state == .changesRequested)
        #expect(reviews[1].user.login == "carol")
    }

    // MARK: - CIStatus roll-up

    @Test func ciStatusNoChecks() {
        #expect(GitHub.CIStatus.roll([]) == .noChecks)
    }

    @Test func ciStatusAllSuccess() throws {
        let pr = try decode(GitHub.PullRequest.self, fixture: "pr-success")
        #expect(GitHub.CIStatus.roll(pr.statusCheckRollup ?? []) == .success)
    }

    @Test func ciStatusFailureWinsOverPending() throws {
        let pr = try decode(GitHub.PullRequest.self, fixture: "pr-failure")
        let status = GitHub.CIStatus.roll(pr.statusCheckRollup ?? [])
        #expect(status == .failure(failingChecks: ["test"]))
    }

    @Test func ciStatusPendingWhenAnyInProgress() {
        let pending = GitHub.CheckRun(
            name: "build", workflowName: "CI",
            status: .inProgress, conclusion: nil, detailsUrl: nil
        )
        let done = GitHub.CheckRun(
            name: "lint", workflowName: "CI",
            status: .completed, conclusion: .success, detailsUrl: nil
        )
        #expect(GitHub.CIStatus.roll([pending, done]) == .pending)
    }

    // MARK: - PR URL parsing

    @Test func parsePRUrl() throws {
        let url = URL(string: "https://github.com/owner/repo/pull/123")!
        let parsed = try GitHubClient.parsePRUrl(url)
        #expect(parsed.owner == "owner")
        #expect(parsed.repo == "repo")
        #expect(parsed.number == 123)
    }

    @Test func parsePRUrlRejectsIssueURL() {
        let url = URL(string: "https://github.com/owner/repo/issues/123")!
        #expect(throws: GitHubClient.Error.self) {
            _ = try GitHubClient.parsePRUrl(url)
        }
    }

    // MARK: - helpers

    private func decode<T: Decodable>(_ type: T.Type, fixture name: String) throws -> T {
        let data = try fixtureData(name)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(T.self, from: data)
    }

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw FixtureError.notFound(name)
        }
        return try Data(contentsOf: url)
    }

    enum FixtureError: Swift.Error {
        case notFound(String)
    }
}
