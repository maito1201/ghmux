import AppKit

final class MainWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1500, height: 950),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "gmux"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.minSize = NSSize(width: 640, height: 400)
        // 状態復元による以前のサイズ・位置の復元を無効化する
        // (これが効いていると contentRect 指定が上書きされてサイズが変わらない)。
        window.isRestorable = false

        let workspace = WorkspaceViewController()
        window.contentViewController = workspace

        self.init(window: window)
        // フレーム自動保存も無効。
        self.shouldCascadeWindows = false
        self.windowFrameAutosaveName = ""
    }

    override func showWindow(_ sender: Any?) {
        applyInitialFrame()
        super.showWindow(sender)
    }

    /// 可視領域に対して大きめの初期サイズを明示設定して中央寄せする。
    private func applyInitialFrame() {
        guard let window else { return }
        let size: NSSize
        if let visible = NSScreen.main?.visibleFrame.size {
            size = NSSize(
                width: min(visible.width * 0.85, 2400),
                height: min(visible.height * 0.9, 1600)
            )
        } else {
            size = NSSize(width: 1500, height: 950)
        }
        window.setContentSize(size)
        window.center()
    }
}
