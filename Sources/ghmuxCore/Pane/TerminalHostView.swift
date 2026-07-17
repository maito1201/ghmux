import AppKit
import Ghostty

/// libghostty Surface をホストするビュー。
final class TerminalHostView: NSView {

    private let surface: Ghostty.Surface

    /// 非アクティブ時に surface へ重ねる半透明のディム矩形。
    /// マウス操作は素通しし (`hitTest` で除外)、フォーカスの無いペインを暗く見せる。
    private let dimOverlay = NonInteractiveOverlay()

    /// surface のフォーカス変化を上位 (ペイン/ワークスペース) へ中継する。
    var onFocusChange: ((Bool) -> Void)? {
        get { surface.onFocusChange }
        set { surface.onFocusChange = newValue }
    }

    /// `workingDirectory` を渡すと端末をそのディレクトリで起動する (分割時の cwd 引き継ぎ用)。
    /// `environment` は PTY プロセスへ注入する追加の環境変数 (例: GHMUX_PANE / GHMUX_SOCK)。
    init(workingDirectory: String? = nil, environment: [String: String] = [:]) {
        self.surface = Ghostty.Surface(
            configuration: .init(workingDirectory: workingDirectory, environment: environment))
        super.init(frame: .zero)
        let surfaceView = surface.makeView()
        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surfaceView)

        dimOverlay.translatesAutoresizingMaskIntoConstraints = false
        dimOverlay.wantsLayer = true
        dimOverlay.layer?.backgroundColor = Ghostty.App.shared.unfocusedSplitFill.cgColor
        dimOverlay.alphaValue = 0 // 既定は非ディム (単一ペイン / アクティブ)。
        addSubview(dimOverlay) // surface の上に重ねる。

        NSLayoutConstraint.activate([
            surfaceView.topAnchor.constraint(equalTo: topAnchor),
            surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),

            dimOverlay.topAnchor.constraint(equalTo: topAnchor),
            dimOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    /// このペインを暗くする/戻す。ghostty config の不透明度で、軽くフェードして切り替える。
    func setDimmed(_ dimmed: Bool) {
        let target = dimmed ? CGFloat(Ghostty.App.shared.unfocusedSplitOverlayAlpha) : 0
        guard dimOverlay.alphaValue != target else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            dimOverlay.animator().alphaValue = target
        }
    }

    /// 端末 (PTY) へ文字列を送る。ClaudeSession のシンクに使う。
    func sendToTerminal(_ text: String) {
        surface.send(text)
    }

    /// 端末へ Enter キーを送り、投入済みコマンドを実行確定する。
    func submitLine() {
        surface.sendReturn()
    }

    /// この端末をキーボードフォーカスにする。
    func focusTerminal() {
        surface.focus()
    }

    /// 端末の現在の作業ディレクトリ (取得不可なら nil)。
    func currentDirectory() -> String? {
        surface.currentDirectory()
    }

    /// 端末内容をテキストで読み取る (`fullScreen`: スクロールバック全体 / それ以外: 可視範囲)。
    func readText(fullScreen: Bool) -> String? {
        surface.readText(fullScreen: fullScreen)
    }
}

/// マウスイベントを一切拾わないオーバーレイ。ディム表示専用で、下の surface に操作を素通しする。
private final class NonInteractiveOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
