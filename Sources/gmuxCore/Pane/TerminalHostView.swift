import AppKit
import Ghostty

/// libghostty Surface をホストするビュー。
final class TerminalHostView: NSView {

    private let surface: Ghostty.Surface

    override init(frame frameRect: NSRect) {
        self.surface = Ghostty.Surface()
        super.init(frame: frameRect)
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
}
