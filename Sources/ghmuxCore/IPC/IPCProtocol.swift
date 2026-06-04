import Foundation

/// ghmux のローカル IPC ワイヤフォーマット (クライアント ⇄ 起動中 GUI)。
///
/// クライアント (`ghmux pane new …`) が Unix domain socket 経由で 1 リクエストを JSON で送り、
/// GUI が 1 レスポンスを返して接続を閉じる短命プロトコル。エンコード/デコードはここに集約し、
/// クライアント側と GUI 側で同じ型を共有する。
public enum IPC {

    /// プロトコルバージョン。後方非互換変更時に上げる。
    public static let version = 1

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
        /// 新しいペインを開き、指定 Issue をアサインする。
        case paneNew = "pane.new"
    }

    /// 分割方向。
    public enum Direction: String, Codable, Sendable {
        case right
        case down
    }

    /// クライアント → GUI のリクエスト。
    public struct Request: Codable, Equatable, Sendable {
        /// プロトコルバージョン。
        public var v: Int
        public var command: Command
        /// アサインする Issue の URL。
        public var issueURL: String
        /// 由来ペインの ID (GHMUX_PANE)。nil なら GUI 側でアクティブペインにフォールバック。
        public var origin: String?
        /// 分割方向。省略時は right。
        public var direction: Direction
        /// 新ペインの作業ディレクトリ。省略時は由来ペインの cwd を引き継ぐ。
        public var workingDirectory: String?

        public init(
            command: Command,
            issueURL: String,
            origin: String? = nil,
            direction: Direction = .right,
            workingDirectory: String? = nil,
            v: Int = IPC.version
        ) {
            self.v = v
            self.command = command
            self.issueURL = issueURL
            self.origin = origin
            self.direction = direction
            self.workingDirectory = workingDirectory
        }
    }

    /// GUI → クライアントのレスポンス。
    public struct Response: Codable, Equatable, Sendable {
        public var v: Int
        public var ok: Bool
        /// 成功時に開いた新ペインの ID。
        public var paneId: String?
        /// 失敗時の理由。
        public var error: String?

        public init(ok: Bool, paneId: String? = nil, error: String? = nil, v: Int = IPC.version) {
            self.v = v
            self.ok = ok
            self.paneId = paneId
            self.error = error
        }

        public static func success(paneId: String) -> Response {
            Response(ok: true, paneId: paneId)
        }

        public static func failure(_ message: String) -> Response {
            Response(ok: false, error: message)
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
