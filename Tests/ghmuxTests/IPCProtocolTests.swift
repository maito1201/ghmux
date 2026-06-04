import Foundation
import Testing
@testable import ghmuxCore

@Suite("IPC ワイヤフォーマット")
struct IPCProtocolTests {

    @Test func requestRoundTrips() throws {
        let req = IPC.Request(
            command: .paneNew,
            issueURL: "https://github.com/acme/widgets/issues/42",
            origin: "pane-123",
            direction: .down,
            workingDirectory: "/tmp/work"
        )
        let data = try IPC.encode(req)
        let decoded = try IPC.decodeRequest(data)
        #expect(decoded == req)
        #expect(decoded.v == IPC.version)
    }

    @Test func responseRoundTrips() throws {
        let ok = IPC.Response.success(paneId: "pane-999")
        #expect(try IPC.decodeResponse(IPC.encode(ok)) == ok)

        let ng = IPC.Response.failure("boom")
        let decoded = try IPC.decodeResponse(try IPC.encode(ng))
        #expect(decoded.ok == false)
        #expect(decoded.error == "boom")
    }

    @Test func encodedMessageEndsWithNewline() throws {
        let data = try IPC.encode(IPC.Request(command: .paneNew, issueURL: "x"))
        #expect(data.last == 0x0A)
    }

    @Test func trailingNewlineIsToleratedOnDecode() throws {
        // JSONDecoder は末尾の空白/改行を許容する。
        let data = try IPC.encode(IPC.Request(command: .paneNew, issueURL: "x"))
        let decoded = try IPC.decodeRequest(data)
        #expect(decoded.issueURL == "x")
    }

    @Test func unknownCommandIsRejected() {
        let json = #"{"v":1,"command":"pane.destroy","issueURL":"x","direction":"right"}"#
        #expect(throws: (any Error).self) {
            try IPC.decodeRequest(Data(json.utf8))
        }
    }

    @Test func defaultsAreApplied() {
        let req = IPC.Request(command: .paneNew, issueURL: "x")
        #expect(req.direction == .right)
        #expect(req.origin == nil)
        #expect(req.workingDirectory == nil)
        #expect(req.v == IPC.version)
    }
}
