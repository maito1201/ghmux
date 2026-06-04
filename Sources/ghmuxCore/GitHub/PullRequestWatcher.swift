import Foundation

/// 1 つの PR について状態を周期的に poll し、差分をイベントとして返す。
///
/// 周期実行は呼出側 (UI レイヤや Combine Timer) の責務とし、`tick()` を呼ぶ単純な
/// インタフェースに留める。これによりテストでは `tick()` を直接呼んで決定的に検証できる。
public actor PullRequestWatcher {

    public let prURL: URL
    private let client: GitHubClient
    private var lastPR: GitHub.PullRequest?
    private var lastCI: GitHub.CIStatus = .noChecks
    private var seenReviewIDs: Set<Int> = []

    public init(prURL: URL, client: GitHubClient) {
        self.prURL = prURL
        self.client = client
    }

    public enum Event: Sendable, Equatable {
        case stateChanged(from: GitHub.PullRequest.State, to: GitHub.PullRequest.State)
        case ciStateChanged(from: GitHub.CIStatus, to: GitHub.CIStatus)
        case mergeableChanged(from: GitHub.PullRequest.Mergeable?, to: GitHub.PullRequest.Mergeable?)
        case reviewAdded(GitHub.Review)
    }

    /// 1 回 polling して差分イベントを返す。
    /// 初回呼び出しでは「過去の状態が無い」ので state/ci/mergeable の "変化" は返さない。
    /// レビューも初回は全件 seen 扱いとして変化として扱わない (履歴の再生を避ける)。
    public func tick() async throws -> [Event] {
        let pr = try await client.fetchPullRequest(url: prURL)
        let reviews = try await client.fetchReviews(prURL: prURL)

        var events: [Event] = []

        if let prev = lastPR {
            if prev.state != pr.state {
                events.append(.stateChanged(from: prev.state, to: pr.state))
            }
            if prev.mergeable != pr.mergeable {
                events.append(.mergeableChanged(from: prev.mergeable, to: pr.mergeable))
            }
            let newCI = GitHub.CIStatus.roll(pr.statusCheckRollup ?? [])
            if newCI != lastCI {
                events.append(.ciStateChanged(from: lastCI, to: newCI))
            }
            for r in reviews where !seenReviewIDs.contains(r.id) {
                events.append(.reviewAdded(r))
            }
        }

        // 状態更新
        lastPR = pr
        lastCI = GitHub.CIStatus.roll(pr.statusCheckRollup ?? [])
        for r in reviews { seenReviewIDs.insert(r.id) }

        return events
    }

    /// 現在キャッシュ済みの PR スナップショット。
    public func snapshot() -> GitHub.PullRequest? { lastPR }
    public func currentCIStatus() -> GitHub.CIStatus { lastCI }
}
