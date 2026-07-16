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
        guard let mainWindowController else {
            return .failure("ワークスペースがありません")
        }
        // origin ペインを含むワークスペースへ振り分ける。見つからなければ選択中へ。
        let workspace = request.origin.flatMap { mainWindowController.workspace(containingPaneId: $0) }
            ?? mainWindowController.activeWorkspace
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

        // Edit メニュー: コピー/ペースト等の標準編集。
        // これが無いと Cmd+C/V/X/A がファーストレスポンダ (設定画面のテキスト欄) へ
        // 配送されない。項目は target=nil で responder chain 経由にし、
        // 編集対象 (NSTextView/NSTextField) が cut:/copy:/paste:/selectAll: を処理する。
        // ターミナルペイン (Ghostty surface) はこれらに応答しないため項目は自動で無効化され、
        // Cmd+C 等はそのまま keyDown → ghostty へ透過する (端末側のコピー挙動は不変)。
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

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

        // Workspace メニュー: 追加 / クローズ / 切替 / ジャンプ。
        // target=nil でファーストレスポンダ経由 → RootViewController が処理する。
        // ペイン系 (⌘] / ⌘[ / ⌘W) と衝突しない修飾キーにする。
        let workspaceMenuItem = NSMenuItem()
        mainMenu.addItem(workspaceMenuItem)
        let workspaceMenu = NSMenu(title: "Workspace")

        let newWorkspace = workspaceMenu.addItem(
            withTitle: "New Workspace",
            action: Selector(("newWorkspace:")),
            keyEquivalent: "n")
        newWorkspace.keyEquivalentModifierMask = [.command]

        let closeWorkspace = workspaceMenu.addItem(
            withTitle: "Close Workspace",
            action: Selector(("closeWorkspace:")),
            keyEquivalent: "w")
        closeWorkspace.keyEquivalentModifierMask = [.command, .shift]

        workspaceMenu.addItem(NSMenuItem.separator())

        let nextWorkspace = workspaceMenu.addItem(
            withTitle: "Next Workspace",
            action: Selector(("selectNextWorkspace:")),
            keyEquivalent: "]")
        nextWorkspace.keyEquivalentModifierMask = [.control, .command]

        let prevWorkspace = workspaceMenu.addItem(
            withTitle: "Previous Workspace",
            action: Selector(("selectPreviousWorkspace:")),
            keyEquivalent: "[")
        prevWorkspace.keyEquivalentModifierMask = [.control, .command]

        workspaceMenu.addItem(NSMenuItem.separator())

        // ⌘1..⌘8 = 1..8 番目、⌘9 = 末尾。tag に番号を入れて 1 セレクタで処理する。
        for n in 1...9 {
            let item = workspaceMenu.addItem(
                withTitle: n == 9 ? "Go to Last Workspace" : "Go to Workspace \(n)",
                action: Selector(("jumpToWorkspace:")),
                keyEquivalent: "\(n)")
            item.keyEquivalentModifierMask = [.command]
            item.tag = n
        }

        workspaceMenuItem.submenu = workspaceMenu

        NSApp.mainMenu = mainMenu
    }
}
