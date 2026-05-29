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

    /// リポジトリの PR 一覧を取得 (open + 直近 closed/merged も含めるため state=all)。
    public func listPullRequests(owner: String, repo: String, limit: Int = 30) async throws -> [GitHub.PullRequest] {
        let data = try await runner.run(arguments: [
            "pr", "list", "--repo", "\(owner)/\(repo)",
            "--state", "all", "--limit", String(limit),
            "--json", Self.prFields,
        ])
        return try decode([GitHub.PullRequest].self, from: data)
    }

    /// Issue 番号を参照する PR を探す。
    /// claude が作成した PR は本文/タイトルに "#<n>" や "closes #<n>" を含む規約を前提とする。
    /// 複数該当時は PR 番号が最大 (最新) のものを返す。
    public func findPullRequest(
        forIssueNumber issueNumber: Int,
        owner: String,
        repo: String
    ) async throws -> GitHub.PullRequest? {
        let prs = try await listPullRequests(owner: owner, repo: repo)
        let matches = prs.filter { Self.references(issueNumber: issueNumber, in: $0) }
        return matches.max(by: { $0.number < $1.number })
    }

    /// PR が指定 Issue 番号を参照しているか (本文・タイトルの "#<n>" を語境界付きで判定)。
    static func references(issueNumber: Int, in pr: GitHub.PullRequest) -> Bool {
        let haystacks = [pr.title, pr.body ?? ""]
        let needle = "#\(issueNumber)"
        for text in haystacks {
            var searchStart = text.startIndex
            while let range = text.range(of: needle, range: searchStart..<text.endIndex) {
                // 直後が数字でない (= #42 が #421 の一部でない) ことを確認。
                let after = range.upperBound
                if after == text.endIndex || !(text[after].isNumber) {
                    return true
                }
                searchStart = after
            }
        }
        return false
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
