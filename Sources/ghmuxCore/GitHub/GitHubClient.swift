import Foundation

/// `gh` CLI を `Process` で呼び出して GitHub API にアクセスするクライアント。
///
/// 認証は `gh auth login` 済み前提。webhook を立てる代わりに polling で利用する。
public actor GitHubClient {

    /// gh CLI を呼ぶための注入可能な runner。テストでは fixture 返却版を差し込む。
    public protocol Runner: Sendable {
        func run(arguments: [String]) async throws -> Data
    }

    public enum Error: Swift.Error, Equatable {
        /// gh が exit code != 0 で終了
        case ghFailed(exitCode: Int32, stderr: String)
        /// JSON パース失敗
        case decode(String)
        /// URL から repo を抽出できなかった
        case invalidURL(String)
    }

    private let runner: Runner
    private let decoder: JSONDecoder

    public init(runner: Runner) {
        self.runner = runner
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public init() {
        self.init(runner: ProcessRunner())
    }

    // MARK: - Public API

    /// Issue URL から Issue 詳細を取得。
    public func fetchIssue(url: URL) async throws -> GitHub.Issue {
        let fields = "number,title,body,url,state,author,labels"
        let data = try await runner.run(arguments: [
            "issue", "view", url.absoluteString, "--json", fields,
        ])
        return try decode(GitHub.Issue.self, from: data)
    }

    /// PR URL から PR 詳細を取得 (CI ロールアップ含む)。
    public func fetchPullRequest(url: URL) async throws -> GitHub.PullRequest {
        let data = try await runner.run(arguments: [
            "pr", "view", url.absoluteString, "--json", Self.prFields,
        ])
        return try decode(GitHub.PullRequest.self, from: data)
    }

    /// Issue に紐づく PR を探す。
    /// GitHub 自身が認識する linked PR (GraphQL closedByPullRequestsReferences) のみを使う。
    /// "Closes #N" 等の linkage を GitHub の判定で拾うので確実。
    public func findPullRequest(
        forIssueNumber issueNumber: Int,
        owner: String,
        repo: String
    ) async throws -> GitHub.PullRequest? {
        guard let url = try await linkedPullRequestURL(owner: owner, repo: repo, issueNumber: issueNumber) else {
            return nil
        }
        return try await fetchPullRequest(url: url)
    }

    /// この Issue に GitHub 上で紐づいている PR の URL を返す。
    ///
    /// `timelineItems` の cross-reference / connected イベントを使う。これにより
    /// - closing keyword (`Closes #N`) で閉じる PR
    /// - 単に Issue を言及 (cross-reference) しただけの PR
    /// - **別リポジトリ**の PR (例: Issue は notahotel/notahotel、PR は notahotel/notahotel-api)
    /// のいずれも GitHub 自身の判定で拾える (テキスト一致ではない)。
    ///
    /// 複数あれば「最後に作成された (最新の) OPEN/MERGED の PR」を優先して 1 件返す。
    public func linkedPullRequestURL(owner: String, repo: String, issueNumber: Int) async throws -> URL? {
        let query = """
        query($owner:String!,$repo:String!,$num:Int!){\
        repository(owner:$owner,name:$repo){issue(number:$num){\
        timelineItems(first:100,itemTypes:[CROSS_REFERENCED_EVENT,CONNECTED_EVENT]){nodes{\
        __typename \
        ... on CrossReferencedEvent{source{__typename ... on PullRequest{url number state createdAt}}} \
        ... on ConnectedEvent{subject{__typename ... on PullRequest{url number state createdAt}}}}}}}}
        """
        let data = try await runner.run(arguments: [
            "api", "graphql",
            "-f", "query=\(query)",
            "-F", "owner=\(owner)",
            "-F", "repo=\(repo)",
            "-F", "num=\(issueNumber)",
        ])
        let resp = try decode(GraphQLLinkedPRResponse.self, from: data)
        let nodes = resp.data.repository?.issue?.timelineItems.nodes ?? []
        // 各イベントから PR を取り出す (CrossReferenced=source / Connected=subject)。
        let prs = nodes.compactMap { $0.source ?? $0.subject }.filter { $0.url != nil }
        guard !prs.isEmpty else { return nil }
        // 1 Issue に複数 PR が紐づく場合、最新 (createdAt 最大) を採用する。
        // 古い PR が後から再参照されると timeline 末尾に来てしまうため、参照順 (.last) ではなく
        // 作成日時で選ぶ。OPEN/MERGED を CLOSED(未マージ)より優先する。
        func newest(_ list: [GraphQLLinkedPRResponse.PRRef]) -> GraphQLLinkedPRResponse.PRRef? {
            list.max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        }
        let active = newest(prs.filter { ($0.state ?? "") != "CLOSED" })
        return (active ?? newest(prs))?.url
    }

    private struct GraphQLLinkedPRResponse: Decodable {
        struct DataField: Decodable { let repository: Repo? }
        struct Repo: Decodable { let issue: Issue? }
        struct Issue: Decodable { let timelineItems: Connection }
        struct Connection: Decodable { let nodes: [Node] }
        struct Node: Decodable {
            let source: PRRef?   // CrossReferencedEvent
            let subject: PRRef?  // ConnectedEvent
        }
        /// source/subject は PR 以外 (Issue 等) のこともあるので url は optional。
        struct PRRef: Decodable {
            let url: URL?
            let number: Int?
            let state: String?
            let createdAt: Date?
        }
        let data: DataField
    }

    /// PR 取得で要求する共通フィールド。
    static let prFields = "number,title,url,state,isDraft,headRefName,baseRefName,mergeable,statusCheckRollup,body"

    /// PR の レビュー一覧を取得 (gh api 経由)。
    public func fetchReviews(prURL: URL) async throws -> [GitHub.Review] {
        let (owner, repo, number) = try Self.parsePRUrl(prURL)
        let data = try await runner.run(arguments: [
            "api", "repos/\(owner)/\(repo)/pulls/\(number)/reviews",
        ])
        return try decode([GitHub.Review].self, from: data)
    }

    // MARK: - URL helpers

    /// `https://github.com/owner/repo/pull/123` → ("owner","repo",123)
    public static func parsePRUrl(_ url: URL) throws -> (owner: String, repo: String, number: Int) {
        // パス: /owner/repo/pull/123
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "pull", let n = Int(parts[3]) else {
            throw Error.invalidURL(url.absoluteString)
        }
        return (parts[0], parts[1], n)
    }

    /// `https://github.com/owner/repo/issues/42` → ("owner","repo",42)
    public static func parseIssueUrl(_ url: URL) throws -> (owner: String, repo: String, number: Int) {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "issues", let n = Int(parts[3]) else {
            throw Error.invalidURL(url.absoluteString)
        }
        return (parts[0], parts[1], n)
    }

    // MARK: - Private

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw Error.decode("decode \(type) failed: \(error)\nbody: \(body)")
        }
    }
}

// MARK: - ProcessRunner

/// `Process` で gh を直接呼ぶ実装。
public struct ProcessRunner: GitHubClient.Runner {

    public var ghPath: String

    public init(ghPath: String = "/opt/homebrew/bin/gh") {
        self.ghPath = ghPath
    }

    public func run(arguments: [String]) async throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ghPath)
        proc.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Swift.Error>) in
            proc.terminationHandler = { p in
                let out = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                let err = String(data: (try? stderr.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
                if p.terminationStatus != 0 {
                    cont.resume(throwing: GitHubClient.Error.ghFailed(
                        exitCode: p.terminationStatus, stderr: err))
                } else {
                    cont.resume(returning: out)
                }
            }
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
