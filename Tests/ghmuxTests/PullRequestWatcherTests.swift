import Foundation
import Testing
@testable import ghmuxCore

@Suite("PullRequestWatcher")
struct PullRequestWatcherTests {

    /// 呼ばれるたびに次の (PR 用 / Reviews 用) fixture を返す Runner。
    final class SequencedRunner: GitHubClient.Runner, @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [Data]

        init(queue: [Data]) { self.queue = queue }

        func run(arguments: [String]) async throws -> Data {
            lock.lock(); defer { lock.unlock() }
            guard !queue.isEmpty else { return Data("{}".utf8) }
            return queue.removeFirst()
        }
    }

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ) else {
            struct E: Error { let name: String }
            throw E(name: name)
        }
        return try Data(contentsOf: url)
    }

    @Test func firstTickProducesNoEventsAndCachesState() async throws {
        let pr = try fixtureData("pr-success")
        let reviews = Data("[]".utf8)
        let client = GitHubClient(runner: SequencedRunner(queue: [pr, reviews]))
        let watcher = PullRequestWatcher(
            prURL: URL(string: "https://github.com/acme/widgets/pull/99")!,
            client: client
        )

        let events = try await watcher.tick()
        #expect(events.isEmpty) // 初回は変化として扱わない
        let snapshot = await watcher.snapshot()
        #expect(snapshot?.number == 99)
        let ci = await watcher.currentCIStatus()
        #expect(ci == .success)
    }

    @Test func ciFailureTransitionEmitsEvent() async throws {
        let success = try fixtureData("pr-success")
        let failure = try fixtureData("pr-failure")
        let emptyReviews = Data("[]".utf8)

        let client = GitHubClient(runner: SequencedRunner(queue: [
            success, emptyReviews,
            failure, emptyReviews,
        ]))
        let watcher = PullRequestWatcher(
            prURL: URL(string: "https://github.com/acme/widgets/pull/99")!,
            client: client
        )

        _ = try await watcher.tick() // 初回
        let events = try await watcher.tick()

        // CI / mergeable 両方変化している (success → failure, MERGEABLE → CONFLICTING)
        // PR number も違う fixture だが、watcher 自体は url で固定なので state比較は走る
        let ciChanged = events.contains { e in
            if case .ciStateChanged(_, let to) = e { return to == .failure(failingChecks: ["test"]) }
            return false
        }
        #expect(ciChanged)

        let mergeableChanged = events.contains { e in
            if case .mergeableChanged(_, let to) = e { return to == .conflicting }
            return false
        }
        #expect(mergeableChanged)
    }

    @Test func newReviewEmitsEventOnlyOnce() async throws {
        let pr = try fixtureData("pr-success")
        let emptyReviews = Data("[]".utf8)
        let oneReview = """
        [{"id": 5001, "user":{"login":"bob"}, "state":"APPROVED", "body":"ok", "submitted_at":"2026-05-28T03:30:00Z"}]
        """.data(using: .utf8)!
        let sameReview = oneReview

        let client = GitHubClient(runner: SequencedRunner(queue: [
            pr, emptyReviews, // tick1: 初回、レビュー無し
            pr, oneReview,    // tick2: 新規レビュー登場
            pr, sameReview,   // tick3: 同じレビュー(変化なし)
        ]))
        let watcher = PullRequestWatcher(
            prURL: URL(string: "https://github.com/acme/widgets/pull/99")!,
            client: client
        )

        _ = try await watcher.tick()
        let t2 = try await watcher.tick()
        let t3 = try await watcher.tick()

        let addedCount = t2.filter {
            if case .reviewAdded = $0 { return true }
            return false
        }.count
        #expect(addedCount == 1)
        #expect(t3.allSatisfy {
            if case .reviewAdded = $0 { return false }
            return true
        })
    }
}
