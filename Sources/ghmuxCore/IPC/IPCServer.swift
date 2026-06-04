import Foundation
import os

private let log = Logger(subsystem: "com.ghmux.core", category: "ipc-server")

/// 起動中 GUI が listen する Unix domain socket サーバー。
///
/// クライアント (`ghmux pane new …`) からの 1 リクエストを受け、`handler` に委譲して
/// 1 レスポンスを返し、接続を閉じる短命プロトコル。`handler` は別スレッドから呼ばれるため、
/// UI 操作を伴う処理はハンドラ内で main へディスパッチし、完了時に completion を呼ぶこと。
public final class IPCServer {

    public enum Error: Swift.Error, CustomStringConvertible {
        case pathTooLong(String)
        case alreadyRunning(String)
        case socketFailed(String)
        case bindFailed(String)
        case listenFailed(String)

        public var description: String {
            switch self {
            case .pathTooLong(let p): return "ソケットパスが長すぎます: \(p)"
            case .alreadyRunning(let p): return "既に別の ghmux が listen 中です: \(p)"
            case .socketFailed(let e): return "socket() 失敗: \(e)"
            case .bindFailed(let e): return "bind() 失敗: \(e)"
            case .listenFailed(let e): return "listen() 失敗: \(e)"
            }
        }
    }

    private let socketPath: String
    /// リクエストを処理し、completion でレスポンスを返すハンドラ。
    private let handler: (IPC.Request, @escaping (IPC.Response) -> Void) -> Void

    private let queue = DispatchQueue(label: "com.ghmux.ipc.server")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    public init(
        socketPath: String = IPC.defaultSocketPath,
        handler: @escaping (IPC.Request, @escaping (IPC.Response) -> Void) -> Void
    ) {
        self.socketPath = socketPath
        self.handler = handler
    }

    deinit { stop() }

    /// サーバーを起動する。stale なソケットは回収するが、生きた別インスタンスがあれば throw。
    public func start() throws {
        guard IPC.makeSockaddrUn(path: socketPath) != nil else {
            throw Error.pathTooLong(socketPath)
        }

        // 親ディレクトリを 0700 で用意。
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        // 既存ソケットの扱い: 生きていれば多重起動として中断、死んでいれば unlink。
        if FileManager.default.fileExists(atPath: socketPath) {
            if isServerAlive() {
                throw Error.alreadyRunning(socketPath)
            }
            unlink(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.socketFailed(errnoString()) }

        var addr = IPC.makeSockaddrUn(path: socketPath)!
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bindResult == 0 else {
            close(fd)
            throw Error.bindFailed(errnoString())
        }
        chmod(socketPath, 0o600)

        guard listen(fd, 8) == 0 else {
            close(fd)
            unlink(socketPath)
            throw Error.listenFailed(errnoString())
        }

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.setCancelHandler { close(fd) }
        acceptSource = src
        src.resume()
        log.info("IPC server listening at \(self.socketPath, privacy: .public)")
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { listenFD = -1 }
        unlink(socketPath)
    }

    // MARK: - 接続処理

    private func acceptOne() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        guard let data = IPC.readMessage(fd: clientFD) else {
            close(clientFD)
            return
        }
        let request: IPC.Request
        do {
            request = try IPC.decodeRequest(data)
        } catch {
            writeAndClose(clientFD, .failure("不正なリクエスト: \(error)"))
            return
        }
        // ハンドラは main へディスパッチして UI 操作する想定。完了時に応答を書いて閉じる。
        handler(request) { [weak self] response in
            self?.queue.async { self?.writeAndClose(clientFD, response) }
        }
    }

    private func writeAndClose(_ fd: Int32, _ response: IPC.Response) {
        if let out = try? IPC.encode(response) {
            out.withUnsafeBytes { raw in
                if let base = raw.baseAddress { _ = write(fd, base, raw.count) }
            }
        }
        close(fd)
    }

    /// 既存パスへ connect を試み、応答すれば「生きたサーバーがいる」と判定する。
    private func isServerAlive() -> Bool {
        guard var addr = IPC.makeSockaddrUn(path: socketPath) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        return r == 0
    }

    private func errnoString() -> String { String(cString: strerror(errno)) }
}
