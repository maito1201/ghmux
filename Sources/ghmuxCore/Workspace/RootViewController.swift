import AppKit

/// ウィンドウの `contentViewController`。左に Issue 一覧サイドバー、右に workspace を並べる。
///
/// `WorkspaceViewController.rebuild()/setRootView()` が自前のビュー階層を毎回貼り直すため、
/// サイドバーを workspace 内に同居させると消える。コンテナ VC で分離して並置する。
final class RootViewController: NSViewController {

    /// IPC ハンドラ等から参照するワークスペース。
    let workspace: WorkspaceViewController
    private let sidebar: IssuesSidebarViewController?

    init(workspace: WorkspaceViewController) {
        self.workspace = workspace
        let repos = GhmuxConfig.current.issues.repositories
        self.sidebar = repos.isEmpty ? nil : IssuesSidebarViewController(repositories: repos)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(workspace:)") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root

        addChild(workspace)
        let w = workspace.view
        w.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(w)

        guard let sidebar else {
            NSLayoutConstraint.activate([
                w.topAnchor.constraint(equalTo: root.topAnchor),
                w.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                w.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                w.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
            return
        }

        addChild(sidebar)
        let s = sidebar.view
        s.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(s)
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: root.topAnchor),
            s.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            s.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            w.topAnchor.constraint(equalTo: root.topAnchor),
            w.leadingAnchor.constraint(equalTo: s.trailingAnchor),
            w.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            w.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }
}
