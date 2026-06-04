import Foundation
import Testing
@testable import ghmuxCore

/// IPCServer ⇄ IPCClient の Unix domain socket 往復を GUI 非依存で検証する。
/// (POSIX socket の bind/accept/read/write と connect/write/read の実配線を確認する)
@Suite("IPC server/client 往復")
struct IPCRoundTripTests {

    /// 短い一時パスを作る (UDS の ~104 byte 制限を確実に満たすため /tmp を使う)。
    private func tempSocketPath() -> String {
        "/tmp/ghmux-test-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test func deliversRequestAndReturnsPaneId() throws {
        let path = tempSocketPath()
        var received: IPC.Request?
        let server = IPCServer(socketPath: path) { request, respond in
            received = request
            respond(.success(paneId: "pane-from-handler"))
        }
        try server.start()
        defer { server.stop() }

        let req = IPC.Request(
            command: .paneNew,
            issueURL: "https://github.com/acme/widgets/issues/7",
            origin: "pane-origin",
            direction: .down
        )
        let response = try IPCClient.send(req, socketPath: path)

        #expect(response.ok)
        #expect(response.paneId == "pane-from-handler")
        #expect(received?.issueURL == "https://github.com/acme/widgets/issues/7")
        #expect(received?.origin == "pane-origin")
        #expect(received?.direction == .down)
    }

    @Test func handlerFailurePropagates() throws {
        let path = tempSocketPath()
        let server = IPCServer(socketPath: path) { _, respond in
            respond(.failure("no pane"))
        }
        try server.start()
        defer { server.stop() }

        let response = try IPCClient.send(
            IPC.Request(command: .paneNew, issueURL: "x"), socketPath: path)
        #expect(response.ok == false)
        #expect(response.error == "no pane")
    }

    @Test func connectFailsWhenNoServer() {
        #expect(throws: (any Error).self) {
            try IPCClient.send(
                IPC.Request(command: .paneNew, issueURL: "x"),
                socketPath: tempSocketPath())
        }
    }

    @Test func deliverFillsOriginFromEnvironment() throws {
        let path = tempSocketPath()
        var received: IPC.Request?
        let server = IPCServer(socketPath: path) { request, respond in
            received = request
            respond(.success(paneId: "p"))
        }
        try server.start()
        defer { server.stop() }

        let code = IPCClient.deliver(
            IPC.Request(command: .paneNew, issueURL: "x"),
            environment: [IPC.paneEnvKey: "env-pane", IPC.socketEnvKey: path])
        #expect(code == 0)
        #expect(received?.origin == "env-pane") // origin 未指定 → 環境変数から補完
    }
}
