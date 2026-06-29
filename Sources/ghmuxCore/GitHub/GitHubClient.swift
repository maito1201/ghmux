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

    /// 指定リポジトリ ("owner/repo") で自分にアサインされた Open Issue を取得。
    /// Issue 一覧サイドバー向け。`fetchIssue` と同じフィールド・デコード経路を使う。
    public func fetchAssignedOpenIssues(repo: String) async throws -> [GitHub.Issue] {
        let fields = "number,title,body,url,state,author,labels"
        let data = try await runner.run(arguments: [
            "issue", "list", "--repo", repo,
            "--assignee", "@me", "--state", "open",
            "--json", fields,
        ])
        return try decode([GitHub.Issue].self, from: data)
    }

    /// PR URL から PR 詳細を取得 (CI ロールアップ含む)。
    public func fetchPullRequest(url: URL) async throws -> GitHub.PullRequest {
        let data = try await runner.run(arguments: [
            "pr", "view", url.absoluteString, "--json", Self.prFields,
        ])
        return try decode(GitHub.PullRequest.self, from: data)
    }

    /// Issue に紐づく PR を 1 件探す。
    /// GitHub 自身が認識する linked PR (GraphQL timeline cross-reference) のみを使う。
    /// 複数紐づく場合は「最新 (createdAt 最大) の OPEN/MERGED」を採用する。
    /// (1 Issue : N PR を扱う UI は `findPullRequests` を使う)
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

    /// Issue に紐づく **全** PR の詳細を返す (CI ロールアップ含む)。
    /// 1 Issue : N PR を許容する UI 向け。作成日時→番号順で安定ソートされる。
    public func findPullRequests(
        forIssueNumber issueNumber: Int,
        owner: String,
        repo: String
    ) async throws -> [GitHub.PullRequest] {
        let urls = try await linkedPullRequestURLs(owner: owner, repo: repo, issueNumber: issueNumber)
        var result: [GitHub.PullRequest] = []
        for url in urls {
            result.append(try await fetchPullRequest(url: url))
        }
        return result
    }

    /// この Issue に GitHub 上で紐づいている PR の URL を返す (最新 OPEN/MERGED を 1 件)。
    ///
    /// 複数あれば「最後に作成された (最新の) OPEN/MERGED の PR」を優先して 1 件返す。
    public func linkedPullRequestURL(owner: String, repo: String, issueNumber: Int) async throws -> URL? {
        let prs = try await linkedPullRequestRefs(owner: owner, repo: repo, issueNumber: issueNumber)
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

    /// この Issue に紐づく **全** PR の URL を作成日時→番号順で返す (重複 URL は除去)。
    /// 1 Issue : N PR を許容する。CLOSED な PR も含めて返す (UI 側で状態を表示する)。
    public func linkedPullRequestURLs(owner: String, repo: String, issueNumber: Int) async throws -> [URL] {
        let prs = try await linkedPullRequestRefs(owner: owner, repo: repo, issueNumber: issueNumber)
        return prs.sorted {
            let a = $0.createdAt ?? .distantPast
            let b = $1.createdAt ?? .distantPast
            if a != b { return a < b }
            return ($0.number ?? 0) < ($1.number ?? 0)
        }.compactMap { $0.url }
    }

    /// timeline の cross-reference / connected イベントから、Issue に紐づく PR 参照を収集する。
    ///
    /// これにより
    /// - closing keyword (`Closes #N`) で閉じる PR
    /// - 単に Issue を言及 (cross-reference) しただけの PR
    /// - **別リポジトリ**の PR (例: Issue は notahotel/notahotel、PR は notahotel/notahotel-api)
    /// のいずれも GitHub 自身の判定で拾える (テキスト一致ではない)。
    /// 同一 PR が複数回参照されることがあるため、URL で重複を除去する。
    private func linkedPullRequestRefs(owner: String, repo: String, issueNumber: Int) async throws -> [GraphQLLinkedPRResponse.PRRef] {
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
        // 同一 PR の重複参照を URL で除去 (初出を保持)。
        var seen = Set<String>()
        var unique: [GraphQLLinkedPRResponse.PRRef] = []
        for pr in prs {
            guard let key = pr.url?.absoluteString else { continue }
            if seen.insert(key).inserted { unique.append(pr) }
        }
        return unique
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
            // stdout/stderr を別スレッドで「プロセス実行中に並行して」読み切る。
            // terminationHandler 後にまとめて読む方式だと、出力がパイプバッファ(約64KB)を
            // 超えたとき gh が書き込みでブロックして終了できず、永久に待つ (デッドロック) ため。
            // Issue 一覧など出力が大きいケースで顕在化する。
            let readQueue = DispatchQueue(label: "ghmux.gh.read", attributes: .concurrent)
            let group = DispatchGroup()
            var outData = Data()
            var errData = Data()

            group.enter()
            readQueue.async {
                outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                group.leave()
            }
            group.enter()
            readQueue.async {
                errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                group.leave()
            }

            proc.terminationHandler = { p in
                // プロセス終了で write 端が閉じ readToEnd が EOF を返すので、読み切りを待つ。
                group.wait()
                if p.terminationStatus != 0 {
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: GitHubClient.Error.ghFailed(
                        exitCode: p.terminationStatus, stderr: err))
                } else {
                    cont.resume(returning: outData)
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
