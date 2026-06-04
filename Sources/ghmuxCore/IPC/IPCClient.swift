import Foundation

/// `ghmux pane new …` のクライアント側。起動中 GUI の Unix domain socket へ接続し、
/// 1 リクエストを送って 1 レスポンスを受け取る。短命なので即座に exit する。
public enum IPCClient {

    public enum Error: Swift.Error, CustomStringConvertible {
        case pathTooLong(String)
        case connectFailed(String)
        case writeFailed(String)
        case noResponse
        case decodeFailed(String)

        public var description: String {
            switch self {
            case .pathTooLong(let p): return "ソケットパスが長すぎます: \(p)"
            case .connectFailed(let e): return "ghmux に接続できません (起動していますか?): \(e)"
            case .writeFailed(let e): return "送信に失敗しました: \(e)"
            case .noResponse: return "応答がありません"
            case .decodeFailed(let e): return "応答の解釈に失敗しました: \(e)"
            }
        }
    }

    /// 環境変数 (GHMUX_PANE / GHMUX_SOCK) を補ってリクエストを送り、結果を標準出力/標準エラーへ
    /// 出力する。プロセスの終了コードを返す (0=成功, それ以外=失敗)。main.swift から呼ぶ想定。
    public static func deliver(
        _ request: IPC.Request,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        var req = request
        // 由来ペインが未指定なら、自分が動いているペインの ID を環境変数から補う。
        if req.origin == nil { req.origin = environment[IPC.paneEnvKey] }
        let socketPath = environment[IPC.socketEnvKey] ?? IPC.defaultSocketPath

        do {
            let response = try send(req, socketPath: socketPath)
            if response.ok {
                if let id = response.paneId {
                    FileHandle.standardOutput.write(Data("opened pane \(id)\n".utf8))
                }
                return 0
            } else {
                FileHandle.standardError.write(Data("ghmux: \(response.error ?? "不明なエラー")\n".utf8))
                return 1
            }
        } catch {
            FileHandle.standardError.write(Data("ghmux: \(error)\n".utf8))
            return 2
        }
    }

    /// 同期的に接続・送信・受信する。
    public static func send(_ request: IPC.Request, socketPath: String) throws -> IPC.Response {
        guard var addr = IPC.makeSockaddrUn(path: socketPath) else {
            throw Error.pathTooLong(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.connectFailed(errnoString()) }
        defer { close(fd) }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard connected == 0 else { throw Error.connectFailed(errnoString()) }

        let payload = try IPC.encode(request)
        let written = payload.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return write(fd, base, raw.count)
        }
        guard written == payload.count else { throw Error.writeFailed(errnoString()) }

        guard let data = IPC.readMessage(fd: fd) else { throw Error.noResponse }
        do {
            return try IPC.decodeResponse(data)
        } catch {
            throw Error.decodeFailed(String(describing: error))
        }
    }

    private static func errnoString() -> String { String(cString: strerror(errno)) }
}
