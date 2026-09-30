import AppKit

/// 既に別の ghmux GUI が listen 中なら、それを前面に出して true を返す (呼び出し側は終了する)。
/// 接続できなければ (未起動、または stale なソケット) false を返し、自分が GUI として起動する。
/// - socketPath: 省略時は GHMUX_SOCK → 既定パス。
public func activateRunningInstance(
    socketPath: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    let path = socketPath ?? environment[IPC.socketEnvKey] ?? IPC.defaultSocketPath
    guard let response = try? IPCClient.send(IPC.Request(command: .appActivate), socketPath: path) else {
        return false
    }
    // 応答があった時点で生きた GUI がいる。pid が取れれば呼び出し側からも activate する
    // (GUI 側の NSApp.activate だけでは前面に出ないことがあるため両側から行う)。
    // 旧バージョンの GUI は app.activate を知らず ok=false を返すので、bundle id で探す。
    let running: NSRunningApplication? =
        response.payload.flatMap { Int32($0) }.flatMap { NSRunningApplication(processIdentifier: $0) }
        ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.ghmux.app").first
    running?.activate(options: [.activateIgnoringOtherApps])
    return true
}

/// `ghmux` 実行バイナリのエントリポイント。`Sources/ghmux/main.swift` から呼ばれる。
public func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)

    // delegate を保持する。`NSApplication.delegate` は weak 参照のため、
    // ローカル変数だけだと即解放される。`run()` 中は scope に居続けるので
    // 明示的に保持しなくても良いが、明確化のため withExtendedLifetime を使う。
    withExtendedLifetime(delegate) {
        app.run()
    }
}
