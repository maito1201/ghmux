import AppKit

final class MainWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "gmux"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.minSize = NSSize(width: 640, height: 400)
        window.center()

        let workspace = WorkspaceViewController()
        window.contentViewController = workspace

        self.init(window: window)
    }
}
