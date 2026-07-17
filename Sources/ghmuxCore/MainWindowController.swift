import AppKit

final class MainWindowController: NSWindowController {

    /// このウィンドウのルート VC。ワークスペース群を保持する。
    private(set) var rootViewController: RootViewController!

    /// 現在選択中のワークスペース (IPC のフォールバック先)。
    var activeWorkspace: WorkspaceViewController { rootViewController.activeWorkspace }

    /// 指定 ID のペインを含むワークスペース (`ghmux pane new` の振り分け用)。
    func workspace(containingPaneId id: String) -> WorkspaceViewController? {
        rootViewController.workspace(containingPaneId: id)
    }

    /// 指定 ID のワークスペース (`ghmux workspace close` の対象指定用)。
    func workspace(withId id: String) -> WorkspaceViewController? {
        rootViewController.workspace(withId: id)
    }

    /// 全ワークスペース/ペインのスナップショット (`ghmux pane list` 用)。
    func workspaceSnapshots() -> [IPC.WorkspaceInfo] {
        rootViewController.workspaceSnapshots()
    }

    /// 新規ワークスペースを追加し、その ID を返す (`ghmux workspace new` 用)。
    @discardableResult
    func addWorkspace() -> String {
        rootViewController.addWorkspace()
    }

    /// 指定 ID のワークスペースを閉じる (`ghmux workspace close` 用)。
    @discardableResult
    func closeWorkspace(withId id: String) -> Bool {
        rootViewController.closeWorkspace(withId: id)
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1500, height: 950),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ghmux"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.minSize = NSSize(width: 640, height: 400)
        // 状態復元による以前のサイズ・位置の復元を無効化する
        // (これが効いていると contentRect 指定が上書きされてサイズが変わらない)。
        window.isRestorable = false

        let root = RootViewController()
        window.contentViewController = root

        self.init(window: window)
        self.rootViewController = root
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
