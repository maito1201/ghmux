import Foundation

/// `ghmux` の引数を解析し、クライアントモードのリクエストを組み立てる純粋ロジック。
///
/// GUI 非依存にすることでテストできる。`origin` (GHMUX_PANE) やソケットパスは環境変数由来なので
/// ここでは扱わず、`IPCClient` が `ProcessInfo` から補う。
public enum CLIParser {

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case missingIssue
        case unknownSubcommand(String)
        case unknownFlag(String)
        case missingValue(flag: String)
        case invalidDirection(String)

        public var description: String {
            switch self {
            case .missingIssue:
                return "--issue <URL> が必要です"
            case .unknownSubcommand(let s):
                return "不明なサブコマンド: \(s)"
            case .unknownFlag(let s):
                return "不明なフラグ: \(s)"
            case .missingValue(let flag):
                return "\(flag) に値がありません"
            case .invalidDirection(let s):
                return "--direction は right|down のいずれか (指定: \(s))"
            }
        }
    }

    /// 使い方の 1 行ヘルプ。
    public static let usage = "usage: ghmux pane new --issue <URL> [--direction right|down] [--cwd <path>]"

    /// `CommandLine.arguments` を解析する。
    /// - Returns: クライアントとして送るべきリクエスト。サブコマンドが無い (GUI 起動) 場合は nil。
    /// - Throws: サブコマンドが指定されたが不正な場合。
    public static func parse(_ arguments: [String]) throws -> IPC.Request? {
        // arguments[0] は実行ファイルパス。
        let args = Array(arguments.dropFirst())

        // サブコマンドが無ければ GUI 起動。
        guard let first = args.first else { return nil }

        // `pane` 以外は GUI 起動として素通しする (Finder 等が付ける引数で誤作動させない)。
        guard first == "pane" else { return nil }

        let rest = Array(args.dropFirst())
        guard rest.first == "new" else {
            throw Error.unknownSubcommand("pane " + (rest.first ?? ""))
        }

        return try parsePaneNew(Array(rest.dropFirst()))
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

        guard let issueURL else { throw Error.missingIssue }
        return IPC.Request(
            command: .paneNew,
            issueURL: issueURL,
            direction: direction,
            workingDirectory: workingDirectory
        )
    }

    /// `--flag value` の value を取り出し、インデックスを value 位置へ進める。
    private static func value(_ flags: [String], after i: inout Int, flag: String) throws -> String {
        guard i + 1 < flags.count else { throw Error.missingValue(flag: flag) }
        i += 1
        return flags[i]
    }
}
