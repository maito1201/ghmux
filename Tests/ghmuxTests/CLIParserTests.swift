import Foundation
import Testing
@testable import ghmuxCore

@Suite("CLIParser")
struct CLIParserTests {

    @Test func noSubcommandLaunchesGUI() throws {
        #expect(try CLIParser.parse(["/path/to/ghmux"]) == nil)
    }

    @Test func unrelatedArgsLaunchGUI() throws {
        // Finder 等が付ける引数で誤作動しない。
        #expect(try CLIParser.parse(["ghmux", "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
    }

    @Test func paneNewWithIssue() throws {
        let req = try CLIParser.parse(["ghmux", "pane", "new", "--issue", "https://x/issues/1"])
        #expect(req?.command == .paneNew)
        #expect(req?.issueURL == "https://x/issues/1")
        #expect(req?.direction == .right) // 既定
    }

    @Test func parsesDirectionDown() throws {
        let req = try CLIParser.parse(["ghmux", "pane", "new", "--issue", "u", "--direction", "down"])
        #expect(req?.direction == .down)
    }

    @Test func parsesCwd() throws {
        let req = try CLIParser.parse(["ghmux", "pane", "new", "--issue", "u", "--cwd", "/tmp/x"])
        #expect(req?.workingDirectory == "/tmp/x")
    }

    @Test func paneNewWithoutIssue() throws {
        // Issue 無しでもペインを作成できる (issueURL は nil)。
        let req = try CLIParser.parse(["ghmux", "pane", "new"])
        #expect(req?.command == .paneNew)
        #expect(req?.issueURL == nil)
        #expect(req?.direction == .right)
    }

    @Test func missingFlagValueThrows() {
        #expect(throws: CLIParser.Error.missingValue(flag: "--issue")) {
            try CLIParser.parse(["ghmux", "pane", "new", "--issue"])
        }
    }

    @Test func invalidDirectionThrows() {
        #expect(throws: CLIParser.Error.invalidDirection("sideways")) {
            try CLIParser.parse(["ghmux", "pane", "new", "--issue", "u", "--direction", "sideways"])
        }
    }

    @Test func unknownFlagThrows() {
        #expect(throws: CLIParser.Error.unknownFlag("--frobnicate")) {
            try CLIParser.parse(["ghmux", "pane", "new", "--issue", "u", "--frobnicate"])
        }
    }

    @Test func unknownPaneSubcommandThrows() {
        #expect(throws: (any Error).self) {
            try CLIParser.parse(["ghmux", "pane", "destroy"])
        }
    }

    // MARK: - pane list / view / close

    @Test func paneList() throws {
        let req = try CLIParser.parse(["ghmux", "pane", "list"])
        #expect(req?.command == .paneList)
    }

    @Test func paneListRejectsExtraArgs() {
        #expect(throws: (any Error).self) {
            try CLIParser.parse(["ghmux", "pane", "list", "extra"])
        }
    }

    @Test func paneViewWithId() throws {
        let req = try CLIParser.parse(["ghmux", "pane", "view", "PANE-1"])
        #expect(req?.command == .paneView)
        #expect(req?.paneId == "PANE-1")
        #expect(req?.viewScope == .screen) // 既定はスクロールバック全体
    }

    @Test func paneViewViewport() throws {
        let req = try CLIParser.parse(["ghmux", "pane", "view", "PANE-1", "--viewport"])
        #expect(req?.viewScope == .viewport)
    }

    @Test func paneViewLines() throws {
        let req = try CLIParser.parse(["ghmux", "pane", "view", "PANE-1", "--lines", "200"])
        #expect(req?.paneId == "PANE-1")
        #expect(req?.lines == 200)
    }

    @Test func paneViewInvalidLinesThrows() {
        #expect(throws: CLIParser.Error.invalidLines("0")) {
            try CLIParser.parse(["ghmux", "pane", "view", "PANE-1", "--lines", "0"])
        }
        #expect(throws: CLIParser.Error.invalidLines("abc")) {
            try CLIParser.parse(["ghmux", "pane", "view", "PANE-1", "--lines", "abc"])
        }
    }

    @Test func paneViewMissingIdThrows() {
        #expect(throws: (any Error).self) {
            try CLIParser.parse(["ghmux", "pane", "view"])
        }
    }

    // MARK: - pane send

    @Test func paneSend() throws {
        let req = try CLIParser.parse(["ghmux", "pane", "send", "PANE-1", "npm test"])
        #expect(req?.command == .paneSend)
        #expect(req?.paneId == "PANE-1")
        #expect(req?.text == "npm test")
        #expect(req?.submit == true) // 既定は Enter 実行
    }

    @Test func paneSendNoEnter() throws {
        let req = try CLIParser.parse(["ghmux", "pane", "send", "PANE-1", "date", "--no-enter"])
        #expect(req?.text == "date")
        #expect(req?.submit == false)
    }

    @Test func paneSendMissingPaneIdThrows() {
        #expect(throws: (any Error).self) {
            try CLIParser.parse(["ghmux", "pane", "send"])
        }
    }

    @Test func paneSendMissingCommandThrows() {
        #expect(throws: (any Error).self) {
            try CLIParser.parse(["ghmux", "pane", "send", "PANE-1"])
        }
    }

    @Test func paneSendEndOfOptionsAllowsDashDashCommand() throws {
        // `--` 以降は先頭が -- のコマンドも位置引数として送れる。
        let req = try CLIParser.parse(["ghmux", "pane", "send", "PANE-1", "--", "--version"])
        #expect(req?.paneId == "PANE-1")
        #expect(req?.text == "--version")
        #expect(req?.submit == true)
    }

    @Test func paneSendRejectsExtraPositional() {
        #expect(throws: (any Error).self) {
            try CLIParser.parse(["ghmux", "pane", "send", "PANE-1", "cmd", "extra"])
        }
    }

    @Test func paneSendUnknownFlagThrows() {
        #expect(throws: CLIParser.Error.unknownFlag("--frob")) {
            try CLIParser.parse(["ghmux", "pane", "send", "PANE-1", "cmd", "--frob"])
        }
    }

    @Test func paneCloseWithoutId() throws {
        let req = try CLIParser.parse(["ghmux", "pane", "close"])
        #expect(req?.command == .paneClose)
        #expect(req?.paneId == nil)
    }

    @Test func paneCloseWithId() throws {
        let req = try CLIParser.parse(["ghmux", "pane", "close", "PANE-2"])
        #expect(req?.command == .paneClose)
        #expect(req?.paneId == "PANE-2")
    }

    // MARK: - workspace new / close

    @Test func workspaceNew() throws {
        let req = try CLIParser.parse(["ghmux", "workspace", "new"])
        #expect(req?.command == .workspaceNew)
    }

    @Test func workspaceCloseWithoutId() throws {
        let req = try CLIParser.parse(["ghmux", "workspace", "close"])
        #expect(req?.command == .workspaceClose)
        #expect(req?.workspaceId == nil)
    }

    @Test func workspaceCloseWithId() throws {
        let req = try CLIParser.parse(["ghmux", "workspace", "close", "WS-1"])
        #expect(req?.command == .workspaceClose)
        #expect(req?.workspaceId == "WS-1")
    }

    @Test func unknownWorkspaceSubcommandThrows() {
        #expect(throws: (any Error).self) {
            try CLIParser.parse(["ghmux", "workspace", "destroy"])
        }
    }
}
