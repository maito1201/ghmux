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

    @Test func missingIssueThrows() {
        #expect(throws: CLIParser.Error.missingIssue) {
            try CLIParser.parse(["ghmux", "pane", "new"])
        }
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
}
