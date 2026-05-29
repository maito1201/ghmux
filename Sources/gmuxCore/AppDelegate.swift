import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let controller = MainWindowController()
        controller.showWindow(self)
        mainWindowController = controller
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
            withTitle: "About gmux",
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
            withTitle: "Quit gmux",
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
