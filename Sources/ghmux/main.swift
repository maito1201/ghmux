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

// 引数なし起動: 既に GUI が動いていれば、それを前面に出して終了する (2 個目の窓を作らない)。
if activateRunningInstance() {
    FileHandle.standardError.write(Data("ghmux: 既に起動中の ghmux を前面に出しました\n".utf8))
    exit(0)
}

runApp()
