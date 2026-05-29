import AppKit

/// `gmux` 実行バイナリのエントリポイント。`Sources/gmux/main.swift` から呼ばれる。
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
