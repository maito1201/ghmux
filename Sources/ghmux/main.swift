import Foundation
import ghmuxCore

// 引数があり、かつクライアントサブコマンド (`pane new …`) なら、起動中 GUI へ指令を送って終了する。
// サブコマンドが無ければ従来どおり GUI を起動する。
do {
    if let request = try CLIParser.parse(CommandLine.arguments) {
        exit(IPCClient.deliver(request))
    }
} catch {
    FileHandle.standardError.write(Data("ghmux: \(error)\n\(CLIParser.usage)\n".utf8))
    exit(64) // EX_USAGE
}

runApp()
