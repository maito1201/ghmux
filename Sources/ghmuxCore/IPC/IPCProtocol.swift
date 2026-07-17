import Foundation

/// ghmux のローカル IPC ワイヤフォーマット (クライアント ⇄ 起動中 GUI)。
///
/// クライアント (`ghmux pane new …`) が Unix domain socket 経由で 1 リクエストを JSON で送り、
/// GUI が 1 レスポンスを返して接続を閉じる短命プロトコル。エンコード/デコードはここに集約し、
/// クライアント側と GUI 側で同じ型を共有する。
public enum IPC {

    /// プロトコルバージョン。後方非互換変更時に上げる。
    /// v2: `pane new` の Issue 任意化と pane/workspace 操作コマンド群を追加。
    /// 受信側はハード拒否しない (混在セッションを壊さないため情報用)。
    public static let version = 2

    /// GUI が listen し、クライアントが接続する Unix domain socket のパス。
    /// 設定と同じ `~/.config/ghmux/` 配下に置く (UDS パス長 ~104 byte 制限内)。
    public static var defaultSocketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/ghmux/ghmux.sock").path
    }

    /// PTY に注入する環境変数名: 由来ペインの ID。
    public static let paneEnvKey = "GHMUX_PANE"
    /// PTY に注入する環境変数名: 接続先ソケットのパス。
    public static let socketEnvKey = "GHMUX_SOCK"

    /// 実行を依頼するコマンドの種類。未知の値はデコード時に拒否する。
    public enum Command: String, Codable, Sendable {
        /// 新しいペインを開く (Issue 指定は任意)。
        case paneNew = "pane.new"
        /// 全ワークスペース/ペインの階層を JSON で返す。
        case paneList = "pane.list"
        /// 指定ペインの端末内容を返す。
        case paneView = "pane.view"
        /// 指定 (or 由来) ペインを閉じる。
        case paneClose = "pane.close"
        /// 指定ペインへ文字列を送る (任意で Enter 実行)。
        case paneSend = "pane.send"
        /// 新しいワークスペースを作成する。
        case workspaceNew = "workspace.new"
        /// 指定 (or 由来/選択中) ワークスペースを閉じる。
        case workspaceClose = "workspace.close"
    }

    /// 分割方向。
    public enum Direction: String, Codable, Sendable {
        case right
        case down
    }

    /// `pane view` で読み取る範囲。
    public enum ViewScope: String, Codable, Sendable {
        /// スクロールバックを含む画面全体。
        case screen
        /// 現在表示中のビューポートのみ。
        case viewport
    }

    /// クライアント → GUI のリクエスト。
    public struct Request: Codable, Equatable, Sendable {
        /// プロトコルバージョン。
        public var v: Int
        public var command: Command
        /// アサインする Issue の URL (任意)。nil なら Issue 無しでペインを開く。
        public var issueURL: String?
        /// 由来ペインの ID (GHMUX_PANE)。nil なら GUI 側でアクティブペインにフォールバック。
        public var origin: String?
        /// 分割方向。省略時は right。
        public var direction: Direction
        /// 新ペインの作業ディレクトリ。省略時は由来ペインの cwd を引き継ぐ。
        public var workingDirectory: String?
        /// 操作対象ペインの ID (`pane view` / `pane close`)。
        public var paneId: String?
        /// 操作対象ワークスペースの ID (`workspace close`)。
        public var workspaceId: String?
        /// `pane view` の読み取り範囲。省略時は screen。
        public var viewScope: ViewScope?
        /// `pane view` で末尾 N 行だけ返す (tail 相当)。省略時は全行。
        public var lines: Int?
        /// `pane send` で送る文字列 (コマンド/指示)。
        public var text: String?
        /// `pane send` で送出後に Enter で実行確定するか。nil は true 相当 (既定で実行)。
        public var submit: Bool?

        public init(
            command: Command,
            issueURL: String? = nil,
            origin: String? = nil,
            direction: Direction = .right,
            workingDirectory: String? = nil,
            paneId: String? = nil,
            workspaceId: String? = nil,
            viewScope: ViewScope? = nil,
            lines: Int? = nil,
            text: String? = nil,
            submit: Bool? = nil,
            v: Int = IPC.version
        ) {
            self.v = v
            self.command = command
            self.issueURL = issueURL
            self.origin = origin
            self.direction = direction
            self.workingDirectory = workingDirectory
            self.paneId = paneId
            self.workspaceId = workspaceId
            self.viewScope = viewScope
            self.lines = lines
            self.text = text
            self.submit = submit
        }
    }

    /// GUI → クライアントのレスポンス。
    public struct Response: Codable, Equatable, Sendable {
        public var v: Int
        public var ok: Bool
        /// 成功時に開いた新ペインの ID。
        public var paneId: String?
        /// 汎用ペイロード。JSON 文書 (`pane list`) or 生の端末テキスト (`pane view`)。
        /// クライアントはデコードせずそのまま stdout へ出力する。
        public var payload: String?
        /// 失敗時の理由。
        public var error: String?

        public init(
            ok: Bool,
            paneId: String? = nil,
            payload: String? = nil,
            error: String? = nil,
            v: Int = IPC.version
        ) {
            self.v = v
            self.ok = ok
            self.paneId = paneId
            self.payload = payload
            self.error = error
        }

        public static func success(paneId: String) -> Response {
            Response(ok: true, paneId: paneId)
        }

        /// 文字列ペイロードを伴う成功レスポンス (`pane list` / `pane view` / `workspace new`)。
        public static func success(payload: String) -> Response {
            Response(ok: true, payload: payload)
        }

        public static func failure(_ message: String) -> Response {
            Response(ok: false, error: message)
        }
    }

    // MARK: - 出力用 DTO (`pane list`)

    /// 紐づく GitHub Issue の状態。
    public struct IssueInfo: Codable, Equatable, Sendable {
        public var url: String
        /// "open" | "closed"。
        public var state: String

        public init(url: String, state: String) {
            self.url = url
            self.state = state
        }
    }

    /// 紐づく GitHub PR の状態。
    public struct PullRequestInfo: Codable, Equatable, Sendable {
        public var url: String
        public var number: Int
        /// "open" | "closed" | "merged"。
        public var state: String
        /// CI ロールアップ: "none" | "pending" | "success" | "failure"。
        public var ci: String
        /// CI 失敗時の失敗チェック名 (それ以外は nil)。
        public var failingChecks: [String]?

        public init(url: String, number: Int, state: String, ci: String, failingChecks: [String]? = nil) {
            self.url = url
            self.number = number
            self.state = state
            self.ci = ci
            self.failingChecks = failingChecks
        }
    }

    /// 1 ペインのスナップショット。
    public struct PaneInfo: Codable, Equatable, Sendable {
        public var paneId: String
        public var workingDirectory: String?
        public var active: Bool
        /// 紐づく Issue (未アサイン or PR 直接投入時は nil)。
        public var issue: IssueInfo?
        /// 紐づく PR 群 (無ければ空)。
        public var pullRequests: [PullRequestInfo]

        public init(
            paneId: String,
            workingDirectory: String?,
            active: Bool,
            issue: IssueInfo? = nil,
            pullRequests: [PullRequestInfo] = []
        ) {
            self.paneId = paneId
            self.workingDirectory = workingDirectory
            self.active = active
            self.issue = issue
            self.pullRequests = pullRequests
        }
    }

    /// 1 ワークスペースのスナップショット。
    public struct WorkspaceInfo: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var selected: Bool
        public var panes: [PaneInfo]

        public init(id: String, name: String, selected: Bool, panes: [PaneInfo]) {
            self.id = id
            self.name = name
            self.selected = selected
            self.panes = panes
        }
    }

    /// `pane list` のペイロード全体。
    public struct PaneListPayload: Codable, Equatable, Sendable {
        public var workspaces: [WorkspaceInfo]
        public var paneCount: Int

        public init(workspaces: [WorkspaceInfo]) {
            self.workspaces = workspaces
            self.paneCount = workspaces.reduce(0) { $0 + $1.panes.count }
        }
    }

    /// リクエストを 1 行の JSON (末尾改行付き) にエンコードする。
    public static func encode(_ request: Request) throws -> Data {
        try frame(request)
    }

    /// レスポンスを 1 行の JSON (末尾改行付き) にエンコードする。
    public static func encode(_ response: Response) throws -> Data {
        try frame(response)
    }

    /// 受信データから Request をデコードする (末尾改行は許容)。
    public static func decodeRequest(_ data: Data) throws -> Request {
        try JSONDecoder().decode(Request.self, from: data)
    }

    /// 受信データから Response をデコードする (末尾改行は許容)。
    public static func decodeResponse(_ data: Data) throws -> Response {
        try JSONDecoder().decode(Response.self, from: data)
    }

    private static func frame<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A) // 改行区切り (1 メッセージ = 1 行)。
        return data
    }

    // MARK: - Unix domain socket ヘルパー (server/client 共有)

    /// パスから `sockaddr_un` を構築する。`sun_path` の容量 (~104 byte) を超える場合は nil。
    static func makeSockaddrUn(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
            rawPtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        return addr
    }

    /// 改行区切り 1 メッセージを fd から読み取る。EOF か改行で終了。
    static func readMessage(fd: Int32, cap: Int = 1 << 20) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < cap {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.last == 0x0A { break }
        }
        return data.isEmpty ? nil : data
    }
}
