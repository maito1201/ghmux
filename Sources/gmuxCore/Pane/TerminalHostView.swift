import AppKit
import Ghostty

/// libghostty Surface をホストするビュー。
final class TerminalHostView: NSView {

    private let surface: Ghostty.Surface

    /// `workingDirectory` を渡すと端末をそのディレクトリで起動する (分割時の cwd 引き継ぎ用)。
    init(workingDirectory: String? = nil) {
        self.surface = Ghostty.Surface(
            configuration: .init(workingDirectory: workingDirectory))
        super.init(frame: .zero)
        let surfaceView = surface.makeView()
        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surfaceView)
        NSLayoutConstraint.activate([
            surfaceView.topAnchor.constraint(equalTo: topAnchor),
            surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    /// 端末 (PTY) へ文字列を送る。ClaudeSession のシンクに使う。
    func sendToTerminal(_ text: String) {
        surface.send(text)
    }

    /// この端末をキーボードフォーカスにする。
    func focusTerminal() {
        surface.focus()
    }

    /// 端末の現在の作業ディレクトリ (取得不可なら nil)。
    func currentDirectory() -> String? {
        surface.currentDirectory()
    }
}
