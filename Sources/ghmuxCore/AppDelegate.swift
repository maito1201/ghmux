import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var ipcServer: IPCServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let controller = MainWindowController()
        controller.showWindow(self)
        mainWindowController = controller
        startIPCServer()
    }

    // MARK: - IPC (ペイン内の claude が `ghmux pane new` で子ペインを開くための受け口)

    private func startIPCServer() {
        let server = IPCServer { [weak self] request, respond in
            // ハンドラは IPC スレッドから呼ばれる。UI 操作のため main へ。
            DispatchQueue.main.async {
                respond(self?.handleIPC(request) ?? .failure("GUI が初期化されていません"))
            }
        }
        do {
            try server.start()
            ipcServer = server
        } catch {
            // 多重起動などは致命的でないのでログのみ (1 個目の GUI が listen を担う)。
            NSLog("ghmux: IPC サーバーを起動できませんでした: \(error)")
        }
    }

    /// main スレッドで IPC リクエストを処理する。
    private func handleIPC(_ request: IPC.Request) -> IPC.Response {
        guard let workspace = mainWindowController?.workspace else {
            return .failure("ワークスペースがありません")
        }
        switch request.command {
        case .paneNew:
            guard let paneId = workspace.openPaneAssigningIssue(
                issueURL: request.issueURL,
                origin: request.origin,
                direction: request.direction,
                cwd: request.workingDirectory
            ) else {
                return .failure("ペインを開けませんでした")
            }
            return .success(paneId: paneId)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.show()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About ghmux",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = appMenu.addItem(
            withTitle: "設定…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit ghmux",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        // Pane メニュー: 分割 / クローズ / フォーカス移動。
        // target=nil でファーストレスポンダ経由 → WorkspaceViewController が処理する。
        let paneMenuItem = NSMenuItem()
        mainMenu.addItem(paneMenuItem)
        let paneMenu = NSMenu(title: "Pane")

        let splitRight = paneMenu.addItem(
            withTitle: "Split Right",
            action: Selector(("splitPaneRight:")),
            keyEquivalent: "d")
        splitRight.keyEquivalentModifierMask = [.command]

        let splitDown = paneMenu.addItem(
            withTitle: "Split Down",
            action: Selector(("splitPaneDown:")),
            keyEquivalent: "d")
        splitDown.keyEquivalentModifierMask = [.command, .shift]

        paneMenu.addItem(NSMenuItem.separator())

        let closePane = paneMenu.addItem(
            withTitle: "Close Pane",
            action: Selector(("closePane:")),
            keyEquivalent: "w")
        closePane.keyEquivalentModifierMask = [.command]

        paneMenu.addItem(NSMenuItem.separator())

        let nextPane = paneMenu.addItem(
            withTitle: "Focus Next Pane",
            action: Selector(("focusNextPane:")),
            keyEquivalent: "]")
        nextPane.keyEquivalentModifierMask = [.command]

        let prevPane = paneMenu.addItem(
            withTitle: "Focus Previous Pane",
            action: Selector(("focusPreviousPane:")),
            keyEquivalent: "[")
        prevPane.keyEquivalentModifierMask = [.command]

        paneMenuItem.submenu = paneMenu

        NSApp.mainMenu = mainMenu
    }
}
