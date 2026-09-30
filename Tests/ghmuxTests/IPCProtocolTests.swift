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

    // MARK: - v2 拡張

    @Test func versionIsTwo() {
        #expect(IPC.version == 2)
    }

    @Test func issueURLIsOptional() throws {
        let req = IPC.Request(command: .paneNew) // Issue 無し
        #expect(req.issueURL == nil)
        let decoded = try IPC.decodeRequest(try IPC.encode(req))
        #expect(decoded == req)
        #expect(decoded.issueURL == nil)
    }

    @Test func newCommandsRoundTrip() throws {
        let commands: [IPC.Command] = [
            .paneList, .paneView, .paneClose, .workspaceNew, .workspaceClose, .appActivate,
        ]
        for cmd in commands {
            let req = IPC.Request(command: cmd)
            #expect(try IPC.decodeRequest(IPC.encode(req)).command == cmd)
        }
    }

    @Test func newRequestFieldsRoundTrip() throws {
        let req = IPC.Request(
            command: .paneView,
            paneId: "pane-7",
            workspaceId: "ws-3",
            viewScope: .viewport)
        let decoded = try IPC.decodeRequest(try IPC.encode(req))
        #expect(decoded == req)
        #expect(decoded.paneId == "pane-7")
        #expect(decoded.workspaceId == "ws-3")
        #expect(decoded.viewScope == .viewport)
    }

    @Test func paneAttachRequestRoundTrips() throws {
        let req = IPC.Request(
            command: .paneAttach, issueURL: "https://github.com/o/r/pull/7", paneId: "pane-1", autoPrompt: false)
        let decoded = try IPC.decodeRequest(try IPC.encode(req))
        #expect(decoded == req)
        #expect(decoded.command == .paneAttach)
        #expect(decoded.paneId == "pane-1")
        #expect(decoded.issueURL == "https://github.com/o/r/pull/7")
        #expect(decoded.autoPrompt == false)
    }

    @Test func paneSendRequestRoundTrips() throws {
        let req = IPC.Request(command: .paneSend, paneId: "pane-1", text: "npm test", submit: false)
        let decoded = try IPC.decodeRequest(try IPC.encode(req))
        #expect(decoded == req)
        #expect(decoded.command == .paneSend)
        #expect(decoded.text == "npm test")
        #expect(decoded.submit == false)
    }

    @Test func responsePayloadRoundTrips() throws {
        let resp = IPC.Response.success(payload: "hello\nworld")
        let decoded = try IPC.decodeResponse(try IPC.encode(resp))
        #expect(decoded.ok)
        #expect(decoded.payload == "hello\nworld")
        #expect(decoded.paneId == nil)
    }

    @Test func paneListPayloadRoundTrips() throws {
        let payload = IPC.PaneListPayload(workspaces: [
            IPC.WorkspaceInfo(id: "ws-1", name: "app", selected: true, panes: [
                IPC.PaneInfo(
                    paneId: "p1",
                    workingDirectory: "/tmp",
                    active: true,
                    issue: IPC.IssueInfo(url: "https://x/issues/1", state: "open"),
                    pullRequests: [
                        IPC.PullRequestInfo(url: "https://x/pull/2", number: 2, state: "open", ci: "success"),
                        IPC.PullRequestInfo(
                            url: "https://x/pull/3", number: 3, state: "open",
                            ci: "failure", failingChecks: ["build", "test"]),
                    ]),
                IPC.PaneInfo(paneId: "p2", workingDirectory: nil, active: false),
            ]),
            IPC.WorkspaceInfo(id: "ws-2", name: "docs", selected: false, panes: []),
        ])
        #expect(payload.paneCount == 2) // 派生カウント
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(IPC.PaneListPayload.self, from: data)
        #expect(decoded == payload)
        #expect(decoded.workspaces[0].panes[0].issue?.state == "open")
        #expect(decoded.workspaces[0].panes[0].pullRequests[1].failingChecks == ["build", "test"])
    }
}
