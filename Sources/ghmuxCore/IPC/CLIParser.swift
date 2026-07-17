import Foundation

/// `ghmux` の引数を解析し、クライアントモードのリクエストを組み立てる純粋ロジック。
///
/// GUI 非依存にすることでテストできる。`origin` (GHMUX_PANE) やソケットパスは環境変数由来なので
/// ここでは扱わず、`IPCClient` が `ProcessInfo` から補う。
public enum CLIParser {

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case unknownSubcommand(String)
        case unknownFlag(String)
        case missingValue(flag: String)
        case invalidDirection(String)
        case missingArgument(String)
        case unexpectedArgument(String)

        public var description: String {
            switch self {
            case .unknownSubcommand(let s):
                return "不明なサブコマンド: \(s)"
            case .unknownFlag(let s):
                return "不明なフラグ: \(s)"
            case .missingValue(let flag):
                return "\(flag) に値がありません"
            case .invalidDirection(let s):
                return "--direction は right|down のいずれか (指定: \(s))"
            case .missingArgument(let what):
                return "\(what) が必要です"
            case .unexpectedArgument(let s):
                return "余分な引数: \(s)"
            }
        }
    }

    /// 使い方の複数行ヘルプ。
    public static let usage = """
    usage:
      ghmux pane new [--issue <URL>] [--direction right|down] [--cwd <path>]
      ghmux pane list
      ghmux pane view <pane_id> [--viewport]
      ghmux pane close [<pane_id>]
      ghmux workspace new
      ghmux workspace close [<workspace_id>]

    別のターミナルからも実行できます (GHMUX_SOCK は任意)。
    対象 ID は `ghmux pane list` で取得してください。
    """

    /// `CommandLine.arguments` を解析する。
    /// - Returns: クライアントとして送るべきリクエスト。サブコマンドが無い (GUI 起動) 場合は nil。
    /// - Throws: サブコマンドが指定されたが不正な場合。
    public static func parse(_ arguments: [String]) throws -> IPC.Request? {
        // arguments[0] は実行ファイルパス。
        let args = Array(arguments.dropFirst())

        // サブコマンドが無ければ GUI 起動。
        guard let first = args.first else { return nil }

        // `pane` / `workspace` 以外は GUI 起動として素通しする (Finder 等が付ける引数で誤作動させない)。
        switch first {
        case "pane":
            return try parsePane(Array(args.dropFirst()))
        case "workspace":
            return try parseWorkspace(Array(args.dropFirst()))
        default:
            return nil
        }
    }

    // MARK: - pane サブコマンド

    private static func parsePane(_ args: [String]) throws -> IPC.Request {
        guard let action = args.first else {
            throw Error.unknownSubcommand("pane")
        }
        let rest = Array(args.dropFirst())
        switch action {
        case "new":
            return try parsePaneNew(rest)
        case "list":
            try expectNoArgs(rest, context: "pane list")
            return IPC.Request(command: .paneList)
        case "view":
            return try parsePaneView(rest)
        case "close":
            let paneId = try optionalPositional(rest, context: "pane close")
            return IPC.Request(command: .paneClose, paneId: paneId)
        default:
            throw Error.unknownSubcommand("pane " + action)
        }
    }

    private static func parsePaneNew(_ flags: [String]) throws -> IPC.Request {
        var issueURL: String?
        var direction: IPC.Direction = .right
        var workingDirectory: String?

        var i = 0
        while i < flags.count {
            let flag = flags[i]
            switch flag {
            case "--issue":
                issueURL = try value(flags, after: &i, flag: flag)
            case "--direction":
                let v = try value(flags, after: &i, flag: flag)
                guard let dir = IPC.Direction(rawValue: v) else { throw Error.invalidDirection(v) }
                direction = dir
            case "--cwd":
                workingDirectory = try value(flags, after: &i, flag: flag)
            default:
                throw Error.unknownFlag(flag)
            }
            i += 1
        }

        return IPC.Request(
            command: .paneNew,
            issueURL: issueURL,
            direction: direction,
            workingDirectory: workingDirectory
        )
    }

    private static func parsePaneView(_ args: [String]) throws -> IPC.Request {
        var paneId: String?
        var scope: IPC.ViewScope = .screen

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--viewport":
                scope = .viewport
            default:
                if arg.hasPrefix("--") { throw Error.unknownFlag(arg) }
                guard paneId == nil else { throw Error.unexpectedArgument(arg) }
                paneId = arg
            }
            i += 1
        }

        guard let paneId else { throw Error.missingArgument("<pane_id>") }
        return IPC.Request(command: .paneView, paneId: paneId, viewScope: scope)
    }

    // MARK: - workspace サブコマンド

    private static func parseWorkspace(_ args: [String]) throws -> IPC.Request {
        guard let action = args.first else {
            throw Error.unknownSubcommand("workspace")
        }
        let rest = Array(args.dropFirst())
        switch action {
        case "new":
            try expectNoArgs(rest, context: "workspace new")
            return IPC.Request(command: .workspaceNew)
        case "close":
            let workspaceId = try optionalPositional(rest, context: "workspace close")
            return IPC.Request(command: .workspaceClose, workspaceId: workspaceId)
        default:
            throw Error.unknownSubcommand("workspace " + action)
        }
    }

    // MARK: - 引数ヘルパー

    /// `--flag value` の value を取り出し、インデックスを value 位置へ進める。
    private static func value(_ flags: [String], after i: inout Int, flag: String) throws -> String {
        guard i + 1 < flags.count else { throw Error.missingValue(flag: flag) }
        i += 1
        return flags[i]
    }

    /// 引数を取らないサブコマンドの検証。
    private static func expectNoArgs(_ args: [String], context: String) throws {
        if let extra = args.first { throw Error.unexpectedArgument(extra) }
    }

    /// 任意の位置引数を 1 つだけ受け取る (フラグ不可、2 つ目以降はエラー)。
    private static func optionalPositional(_ args: [String], context: String) throws -> String? {
        guard let first = args.first else { return nil }
        if first.hasPrefix("--") { throw Error.unknownFlag(first) }
        if args.count > 1 { throw Error.unexpectedArgument(args[1]) }
        return first
    }
}
