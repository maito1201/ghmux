import Foundation

/// GitHub の Issue / PR / CI / Review を gh CLI の JSON 出力から `Codable` で復元するための型。
///
/// gh の JSON フィールド名は GraphQL ベースの camelCase。Swift の自然な命名と一致するため、
/// 多くのプロパティで `CodingKeys` を省略している。
public enum GitHub {

    // MARK: - Issue

    public struct Issue: Codable, Equatable, Sendable {
        public let number: Int
        public let title: String
        public let body: String
        public let url: URL
        public let state: State
        public let author: Actor?
        public let labels: [Label]

        public enum State: String, Codable, Sendable {
            case open = "OPEN"
            case closed = "CLOSED"
        }
    }

    // MARK: - PullRequest

    public struct PullRequest: Codable, Equatable, Sendable {
        public let number: Int
        public let title: String
        public let url: URL
        public let state: State
        public let isDraft: Bool
        public let headRefName: String
        public let baseRefName: String
        public let mergeable: Mergeable?
        public let statusCheckRollup: [CheckRun]?
        /// PR 本文。Issue 番号参照 (例 "closes #42") の照合に使う。
        /// `gh pr list --json body` で取得。fixture によっては欠落しうるため optional。
        public let body: String?

        public enum State: String, Codable, Sendable {
            case open = "OPEN"
            case closed = "CLOSED"
            case merged = "MERGED"
        }

        public enum Mergeable: String, Codable, Sendable {
            case mergeable = "MERGEABLE"
            case conflicting = "CONFLICTING"
            case unknown = "UNKNOWN"
        }
    }

    // MARK: - CheckRun

    public struct CheckRun: Codable, Equatable, Sendable {
        public let name: String
        /// gh の statusCheckRollup は workflow 名でグルーピングされる。
        /// 単体チェックでは省略されるので Optional。
        public let workflowName: String?
        public let status: Status
        public let conclusion: Conclusion?
        public let detailsUrl: URL?

        public enum Status: String, Codable, Sendable {
            case queued    = "QUEUED"
            case inProgress = "IN_PROGRESS"
            case completed = "COMPLETED"
            case waiting   = "WAITING"
            case pending   = "PENDING"
            case requested = "REQUESTED"
            /// gh が想定外/空の値を返したときのフォールバック (= 完了扱いしない)。
            case unknown   = "UNKNOWN"
        }

        public enum Conclusion: String, Codable, Sendable {
            case success  = "SUCCESS"
            case failure  = "FAILURE"
            case neutral  = "NEUTRAL"
            case cancelled = "CANCELLED"
            case skipped  = "SKIPPED"
            case timedOut = "TIMED_OUT"
            case actionRequired = "ACTION_REQUIRED"
            case stale    = "STALE"
            case startupFailure = "STARTUP_FAILURE"
        }

        public init(
            name: String,
            workflowName: String?,
            status: Status,
            conclusion: Conclusion?,
            detailsUrl: URL?
        ) {
            self.name = name
            self.workflowName = workflowName
            self.status = status
            self.conclusion = conclusion
            self.detailsUrl = detailsUrl
        }

        enum CodingKeys: String, CodingKey {
            case name, workflowName, status, conclusion, detailsUrl
        }

        /// 寛容なデコード。gh は未完了チェックで conclusion に空文字 "" を返すことがあり、
        /// `decodeIfPresent` では nil にならず enum デコードに失敗する (dataCorrupted) ため、
        /// 文字列として読んでから enum へ写像する。未知/空の値は安全側に倒す。
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            workflowName = (try? c.decodeIfPresent(String.self, forKey: .workflowName)) ?? nil

            let statusRaw = ((try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil) ?? ""
            status = Status(rawValue: statusRaw) ?? .unknown

            let concRaw = ((try? c.decodeIfPresent(String.self, forKey: .conclusion)) ?? nil) ?? ""
            conclusion = concRaw.isEmpty ? nil : Conclusion(rawValue: concRaw)

            // 空文字 URL 等で失敗しても nil に倒す。
            detailsUrl = (try? c.decodeIfPresent(URL.self, forKey: .detailsUrl)) ?? nil
        }
    }

    /// PR 全体の CI 状態のロールアップ。`CheckRun` リストから判定する。
    public enum CIStatus: Equatable, Sendable {
        case noChecks
        case pending
        case success
        case failure(failingChecks: [String])

        public static func roll(_ checks: [CheckRun]) -> CIStatus {
            guard !checks.isEmpty else { return .noChecks }

            let failed = checks.filter {
                $0.conclusion == .failure ||
                $0.conclusion == .cancelled ||
                $0.conclusion == .timedOut
            }
            if !failed.isEmpty {
                return .failure(failingChecks: failed.map(\.name))
            }
            if checks.contains(where: { $0.status != .completed }) {
                return .pending
            }
            return .success
        }
    }

    // MARK: - Review

    public struct Review: Codable, Equatable, Sendable {
        public let id: Int
        public let user: Actor
        public let state: State
        public let body: String
        public let submittedAt: Date?

        public enum State: String, Codable, Sendable {
            case approved        = "APPROVED"
            case changesRequested = "CHANGES_REQUESTED"
            case commented       = "COMMENTED"
            case dismissed       = "DISMISSED"
            case pending         = "PENDING"
        }

        private enum CodingKeys: String, CodingKey {
            case id, user, state, body
            case submittedAt = "submitted_at" // gh api (REST) は snake_case
        }
    }

    // MARK: - Shared

    public struct Actor: Codable, Equatable, Sendable {
        public let login: String
    }

    public struct Label: Codable, Equatable, Sendable {
        public let name: String
        public let color: String?
    }
}
