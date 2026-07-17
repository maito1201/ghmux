import AppKit

/// ウィンドウの `contentViewController`。
///
/// 左カラム (Issue 一覧=上 / ワークスペース一覧=下) と、右側の選択中ワークスペースを並べる。
/// 複数の `WorkspaceViewController` (各々が独立したペイン分割ツリー) を配列で保持し、
/// 左下の一覧で切り替える。切替時は右側に選択中の view のみを差し込み、他のワークスペースは
/// 子 VC として保持し続けて端末/スクロールバックを維持する。
///
/// サイドバー類を `WorkspaceViewController` 内に同居させないのは、
/// `WorkspaceViewController.rebuild()/setRootView()` が自前のビュー階層を毎回貼り直すため。
/// この RootViewController は再構築されない唯一のコンテナなので、常設 UI はここに置く。
final class RootViewController: NSViewController {

    /// 保持する全ワークスペース (表示順)。
    private var workspaces: [WorkspaceViewController] = []
    /// 現在選択中のインデックス (0..<workspaces.count)。
    private var selectedIndex: Int = 0

    private let issuesSidebar: IssuesSidebarViewController?
    private let workspacesSidebar = WorkspacesSidebarViewController()

    /// 選択中ワークスペースの view を載せる右側コンテナ。
    private let rightHost = NSView()
    /// 左カラム幅 (折りたたみで 280↔32)。幅の所有はここ。
    private var leftWidthConstraint: NSLayoutConstraint!

    init() {
        let repos = GhmuxConfig.current.issues.repositories
        self.issuesSidebar = repos.isEmpty ? nil : IssuesSidebarViewController(repositories: repos)
        super.init(nibName: nil, bundle: nil)
        addInitialWorkspace()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    // MARK: - 公開 (IPC ルーティング用)

    /// 現在選択中のワークスペース。
    var activeWorkspace: WorkspaceViewController { workspaces[selectedIndex] }

    /// 指定 ID のペインを含むワークスペースを返す (`ghmux pane new` の振り分け用)。
    func workspace(containingPaneId id: String) -> WorkspaceViewController? {
        workspaces.first { $0.contains(paneId: id) }
    }

    /// 指定 ID のワークスペースを返す (`ghmux workspace close` の対象指定用)。
    func workspace(withId id: String) -> WorkspaceViewController? {
        workspaces.first { $0.id == id }
    }

    /// 全ワークスペース/ペインのスナップショット (`ghmux pane list` 用)。
    func workspaceSnapshots() -> [IPC.WorkspaceInfo] {
        workspaces.enumerated().map { index, ws in
            IPC.WorkspaceInfo(
                id: ws.id,
                name: displayName(for: ws),
                selected: index == selectedIndex,
                panes: ws.paneSnapshots())
        }
    }

    /// 指定 ID のワークスペースを閉じる (`ghmux workspace close` 用)。
    /// ID 不在 or 残り 1 個なら false。
    @discardableResult
    func closeWorkspace(withId id: String) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == id }), workspaces.count > 1 else {
            return false
        }
        closeWorkspace(at: index)
        return true
    }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root

        // 左カラム: 幅は leftWidthConstraint が所有。
        let leftColumn = NSView()
        leftColumn.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(leftColumn)

        // 右側ホスト。
        rightHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rightHost)

        leftWidthConstraint = leftColumn.widthAnchor.constraint(
            equalToConstant: IssuesSidebarViewController.expandedWidth)

        NSLayoutConstraint.activate([
            // 左カラム上端は safe area に合わせトラフィックライトを避ける。
            leftColumn.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            leftColumn.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            leftColumn.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            leftWidthConstraint,

            // 右側は上端を root に合わせる (内部の workspace が自前の safe area で調整する)。
            rightHost.topAnchor.constraint(equalTo: root.topAnchor),
            rightHost.leadingAnchor.constraint(equalTo: leftColumn.trailingAnchor),
            rightHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rightHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        buildLeftColumn(in: leftColumn)
        wireCallbacks()
        embedSelectedWorkspace()
        reloadWorkspacesSidebar()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // 初期ワークスペースの cwd はシェル起動後に判明するため、少し遅れて名前を反映する。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.reloadWorkspacesSidebar()
        }
    }

    /// 左カラムの中身を組む。Issue 一覧があれば縦分割 (上=Issue / 下=Workspaces)、
    /// 無ければワークスペース一覧が左カラム全体を占有する。
    private func buildLeftColumn(in leftColumn: NSView) {
        addChild(workspacesSidebar)
        let wsView = workspacesSidebar.view

        if let issuesSidebar {
            addChild(issuesSidebar)
            let split = BinarySplitView(
                direction: .vertical,
                ratio: 0.6,
                first: issuesSidebar.view,
                second: wsView
            )
            split.translatesAutoresizingMaskIntoConstraints = false
            leftColumn.addSubview(split)
            NSLayoutConstraint.activate([
                split.topAnchor.constraint(equalTo: leftColumn.topAnchor),
                split.leadingAnchor.constraint(equalTo: leftColumn.leadingAnchor),
                split.trailingAnchor.constraint(equalTo: leftColumn.trailingAnchor),
                split.bottomAnchor.constraint(equalTo: leftColumn.bottomAnchor),
            ])
        } else {
            wsView.translatesAutoresizingMaskIntoConstraints = false
            leftColumn.addSubview(wsView)
            NSLayoutConstraint.activate([
                wsView.topAnchor.constraint(equalTo: leftColumn.topAnchor),
                wsView.leadingAnchor.constraint(equalTo: leftColumn.leadingAnchor),
                wsView.trailingAnchor.constraint(equalTo: leftColumn.trailingAnchor),
                wsView.bottomAnchor.constraint(equalTo: leftColumn.bottomAnchor),
            ])
        }
    }

    private func wireCallbacks() {
        workspacesSidebar.onAdd = { [weak self] in self?.addWorkspace() }
        workspacesSidebar.onSelect = { [weak self] i in self?.selectWorkspace(at: i) }
        workspacesSidebar.onClose = { [weak self] i in self?.closeWorkspace(at: i) }
        workspacesSidebar.onReorder = { [weak self] from, to in self?.moveWorkspace(from: from, to: to) }
        workspacesSidebar.onRename = { [weak self] i, name in self?.renameWorkspace(at: i, to: name) }

        issuesSidebar?.onToggleCollapse = { [weak self] collapsed in
            self?.setLeftColumnCollapsed(collapsed)
        }
    }

    // MARK: - 折りたたみ

    private func setLeftColumnCollapsed(_ collapsed: Bool) {
        workspacesSidebar.setContentHidden(collapsed)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            leftWidthConstraint.animator().constant = collapsed
                ? IssuesSidebarViewController.collapsedWidth
                : IssuesSidebarViewController.expandedWidth
            view.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - ワークスペース管理

    private func addInitialWorkspace() {
        // 初回はシェル既定 cwd で開く (名前はシェル起動後に activeDirectory から反映)。
        let ws = WorkspaceViewController(workingDirectory: nil)
        workspaces = [ws]
        selectedIndex = 0
        addChild(ws)
    }

    /// 新規ワークスペースを末尾に追加して選択する。cmux 同様、現在のワークスペースの
    /// 作業ディレクトリを引き継いで開き、そのディレクトリ名を既定の表示名にする。
    /// - Returns: 追加したワークスペースの ID (`ghmux workspace new` が返す)。
    @discardableResult
    func addWorkspace() -> String {
        let dir = activeWorkspace.activeDirectory()
        let ws = WorkspaceViewController(workingDirectory: dir)
        addChild(ws)
        workspaces.append(ws)
        selectWorkspace(at: workspaces.count - 1)
        return ws.id
    }

    /// 指定位置のワークスペースの表示名を変更する (空なら既定=ディレクトリ名に戻す)。
    func renameWorkspace(at index: Int, to name: String) {
        guard workspaces.indices.contains(index) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaces[index].customName = trimmed.isEmpty ? nil : trimmed
        reloadWorkspacesSidebar()
    }

    /// 表示名を解決する。ユーザー命名 > 現在の cwd 名 > 生成時ディレクトリ名 > "shell"。
    private func displayName(for ws: WorkspaceViewController) -> String {
        if let custom = ws.customName, !custom.isEmpty { return custom }
        let dir = ws.activeDirectory() ?? ws.creationDirectory
        guard let dir, !dir.isEmpty else { return "shell" }
        let base = (dir as NSString).lastPathComponent
        return base.isEmpty ? dir : base
    }

    /// 指定位置のワークスペースを閉じる。残り 1 個なら何もしない (`closePane` と同方針)。
    func closeWorkspace(at index: Int) {
        guard workspaces.count > 1, workspaces.indices.contains(index) else { return }
        let ws = workspaces.remove(at: index)
        if ws.isViewLoaded { ws.view.removeFromSuperview() }
        ws.removeFromParent()
        // 選択位置を補正する。閉じたのが選択中/より前なら詰める。
        if selectedIndex >= workspaces.count {
            selectedIndex = workspaces.count - 1
        } else if index < selectedIndex {
            selectedIndex -= 1
        }
        embedSelectedWorkspace()
        reloadWorkspacesSidebar()
        activeWorkspace.focusActivePane()
    }

    /// 指定位置のワークスペースへ切り替える。
    func selectWorkspace(at index: Int) {
        guard workspaces.indices.contains(index) else { return }
        selectedIndex = index
        embedSelectedWorkspace()
        reloadWorkspacesSidebar()
        activeWorkspace.focusActivePane()
    }

    /// from の位置のワークスペースを to の位置へ移動する (ドラッグ並べ替え)。
    func moveWorkspace(from: Int, to: Int) {
        guard workspaces.indices.contains(from), to >= 0, to < workspaces.count, from != to else { return }
        let selected = workspaces[selectedIndex]
        let ws = workspaces.remove(at: from)
        workspaces.insert(ws, at: to)
        selectedIndex = workspaces.firstIndex { $0 === selected } ?? selectedIndex
        reloadWorkspacesSidebar()
    }

    /// 選択中ワークスペースの view のみを右側に載せる (他は子 VC として保持し続ける)。
    private func embedSelectedWorkspace() {
        for sub in rightHost.subviews { sub.removeFromSuperview() }
        let content = activeWorkspace.view
        content.translatesAutoresizingMaskIntoConstraints = false
        rightHost.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: rightHost.topAnchor),
            content.leadingAnchor.constraint(equalTo: rightHost.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: rightHost.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: rightHost.bottomAnchor),
        ])
    }

    private func reloadWorkspacesSidebar() {
        workspacesSidebar.reload(
            titles: workspaces.map { displayName(for: $0) },
            selectedIndex: selectedIndex)
    }

    // MARK: - メニューアクション (responder chain 経由)

    @objc func newWorkspace(_ sender: Any?) { addWorkspace() }

    @objc func closeWorkspace(_ sender: Any?) { closeWorkspace(at: selectedIndex) }

    @objc func selectNextWorkspace(_ sender: Any?) {
        guard !workspaces.isEmpty else { return }
        selectWorkspace(at: (selectedIndex + 1) % workspaces.count)
    }

    @objc func selectPreviousWorkspace(_ sender: Any?) {
        guard !workspaces.isEmpty else { return }
        selectWorkspace(at: (selectedIndex - 1 + workspaces.count) % workspaces.count)
    }

    /// `⌘1`…`⌘8` = 1..8 番目、`⌘9` = 末尾。メニュー項目の tag に番号を入れる。
    @objc func jumpToWorkspace(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag else { return }
        let index = (tag == 9) ? workspaces.count - 1 : tag - 1
        selectWorkspace(at: index)
    }
}
