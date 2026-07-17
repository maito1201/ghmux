import AppKit

/// 複数 `PaneViewController` を分割表示するコンテナ。
///
/// Ghostty 本家に倣い、`NSSplitView` を使わず**自前の比率ベース分割ビュー** (`BinarySplitView`) と
/// **二分木モデル** (`SplitNode`) で実装する。NSSplitView のネストは内部制約が壊れやすく、
/// 非対称レイアウトでディバイダが固着する問題があるため。
///
/// `PaneViewController` は全て WorkspaceViewController の子 VC とし (責任の単純化)、
/// view だけを `BinarySplitView` の階層に配置する。比率はノードに保持するので構造変更後も保たれる。
///
/// - Cmd+D       : フォーカス中ペインを左右分割
/// - Cmd+Shift+D : フォーカス中ペインを上下分割
/// - Cmd+W       : フォーカス中ペインを閉じる
/// - Cmd+] / [   : フォーカスを次/前のペインへ
final class WorkspaceViewController: NSViewController {

    /// レイアウト二分木。葉 = ペイン、節 = 方向 + 比率 + 左右の子。
    private final class SplitNode {
        var pane: PaneViewController?
        var direction: BinarySplitView.Direction?
        var left: SplitNode?
        var right: SplitNode?
        var ratio: CGFloat = 0.5

        var isLeaf: Bool { pane != nil }

        static func leaf(_ p: PaneViewController) -> SplitNode {
            let n = SplitNode(); n.pane = p; return n
        }
    }

    private var root: SplitNode!
    private var rootView: NSView?
    /// 進行中のペインドラッグの元 ID (オーバーレイ表示の除外用)。
    private var draggingPaneId: String?

    /// 安定したワークスペース ID (CLI/IPC からの対象指定用)。配列 index と違い並べ替え/クローズで変わらない。
    let id: String = UUID().uuidString

    /// 最初のペインを起動する作業ディレクトリ (ワークスペース生成元から引き継ぐ)。
    let creationDirectory: String?
    /// ユーザーが付けた表示名 (未設定ならディレクトリ名から導出する)。
    var customName: String?

    init(workingDirectory: String? = nil) {
        self.creationDirectory = workingDirectory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(workingDirectory:)") }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = v

        let p = makePane(workingDirectory: creationDirectory)
        root = .leaf(p)
        rebuild()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        collectPanes().first?.focusTerminal()
    }

    /// アクティブ (無ければ先頭) ペインへフォーカスする。
    /// ワークスペース切替でこの view が再表示されたとき、呼び出し側から明示的に使う。
    func focusActivePane() {
        (activePane() ?? collectPanes().first)?.focusTerminal()
    }

    /// アクティブ (無ければ先頭) ペインの現在の作業ディレクトリ (表示名の導出用)。
    func activeDirectory() -> String? {
        (activePane() ?? collectPanes().first)?.currentDirectory()
    }

    // MARK: - 生成

    private func makePane(workingDirectory: String? = nil) -> PaneViewController {
        let p = PaneViewController(workingDirectory: workingDirectory)
        // 分割ボタン: 押されたペイン自身を分割する (フォーカス非依存)。
        p.onRequestSplitRight = { [weak self, weak p] in
            guard let self, let p else { return }
            self.splitFrom(p, direction: .horizontal)
        }
        p.onRequestSplitDown = { [weak self, weak p] in
            guard let self, let p else { return }
            self.splitFrom(p, direction: .vertical)
        }
        // ヘッダドラッグ: このペインの再配置を開始する。
        p.onRequestBeginDrag = { [weak self, weak p] event in
            self?.beginPaneDrag(p, event: event)
        }
        // ドロップ: ドラッグ中ペインをこのペインの指定端へ移動する。
        p.dropOverlay.onDrop = { [weak self, weak p] draggedId, edge in
            guard let self, let p else { return false }
            return self.movePane(draggedId, ontoEdgeOf: p.paneId, edge: edge)
        }
        // フォーカスが移ったら全ペインのディム状態を再計算する (マウスクリック含む)。
        p.onFocusChange = { [weak self] _ in self?.scheduleDimRefresh() }
        return p
    }

    // MARK: - 非アクティブペインのディム

    /// フォーカス遷移中は firstResponder が一瞬 nil / window になり得るため、
    /// 状態が確定する次の runloop で再計算する。
    private func scheduleDimRefresh() {
        DispatchQueue.main.async { [weak self] in self?.refreshPaneDimming() }
    }

    /// 各ペインのディムを更新する。複数ペインのとき、アクティブ以外を暗くする。
    private func refreshPaneDimming() {
        let panes = collectPanes()
        let split = panes.count > 1
        let active = activePane()
        for p in panes { p.setDimmed(split && p !== active) }
    }

    // MARK: - ツリー走査

    private func collectPanes() -> [PaneViewController] {
        var result: [PaneViewController] = []
        func walk(_ n: SplitNode) {
            if let p = n.pane { result.append(p) }
            else { n.left.map(walk); n.right.map(walk) }
        }
        if let root { walk(root) }
        return result
    }

    private func findLeaf(_ pane: PaneViewController) -> SplitNode? {
        func walk(_ n: SplitNode) -> SplitNode? {
            if n.pane === pane { return n }
            return n.left.flatMap(walk) ?? n.right.flatMap(walk)
        }
        return root.flatMap(walk)
    }

    /// 指定 ID のペインを探す (IPC/CLI の origin 解決用)。
    private func pane(withId id: String) -> PaneViewController? {
        collectPanes().first { $0.paneId == id }
    }

    /// このワークスペースが指定 ID のペインを含むか (IPC のワークスペース振り分け用)。
    func contains(paneId id: String) -> Bool {
        pane(withId: id) != nil
    }

    // MARK: - 階層の再構築

    /// ツリーから view 階層を組み直し、ワークスペースに固定する。
    /// 各ペインは WorkspaceViewController の子 VC として保持し、view のみ再配置する。
    private func rebuild() {
        let panes = collectPanes()
        // 不要になった子 VC を外す。
        for child in children.compactMap({ $0 as? PaneViewController }) where !panes.contains(where: { $0 === child }) {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        // tree 内のペインを子 VC に登録 (未登録のみ)。
        for p in panes where p.parent == nil { addChild(p) }

        let content = buildView(root)
        setRootView(content)
        // 分割/移動/クローズでペイン数やアクティブが変わるので、ディムを追従させる。
        scheduleDimRefresh()
    }

    private func buildView(_ node: SplitNode) -> NSView {
        if let pane = node.pane {
            return pane.view
        }
        let sv = BinarySplitView(
            direction: node.direction ?? .horizontal,
            ratio: node.ratio,
            first: buildView(node.left!),
            second: buildView(node.right!)
        )
        sv.onRatioChange = { [weak node] r in node?.ratio = r }
        return sv
    }

    private func setRootView(_ content: NSView) {
        // 旧ルート直下ビューのうち content 以外を除去する。
        // ペイン view は buildView で既に content 配下へ移動済みなので、ここで消えるのは
        // 古い空の split view だけ。rootView?.removeFromSuperview() だと「新 split の子に
        // なった旧ルートペイン」を引き剥がしてしまうため、この方式にしている。
        for sub in view.subviews where sub !== content {
            sub.removeFromSuperview()
        }
        rootView = content
        // content がまだ workspace 直下に無ければ追加・固定する。
        // safeAreaLayoutGuide に固定することで、fullSizeContentView + 透明タイトルバー時に
        // トラフィックライト/タイトルバー分の上マージンが自動確保され、Issue 入力欄との重なりを防ぐ。
        // フルスクリーン時はタイトルバーが隠れて safe area top が 0 になり、コンテンツが全面に広がる。
        if content.superview !== view {
            content.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(content)
            let guide = view.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: guide.topAnchor),
                content.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            ])
        }
    }

    // MARK: - フォーカス中ペイン

    private func activePane() -> PaneViewController? {
        if let responder = view.window?.firstResponder as? NSView {
            for pane in collectPanes() where responder.isDescendant(of: pane.view) {
                return pane
            }
        }
        return collectPanes().first
    }

    // MARK: - 分割

    @objc func splitPaneRight(_ sender: Any?) { doSplit(.horizontal) }
    @objc func splitPaneDown(_ sender: Any?) { doSplit(.vertical) }

    private func doSplit(_ direction: BinarySplitView.Direction) {
        guard let active = activePane() else { return }
        splitFrom(active, direction: direction)
    }

    /// `base` ペインを基点に分割し、新ペインを返す。
    /// `cwd` 省略時は基点ペインの現在の作業ディレクトリを引き継ぐ (cmux/ghostty と同挙動)。
    @discardableResult
    private func splitFrom(
        _ base: PaneViewController,
        direction: BinarySplitView.Direction,
        cwd: String? = nil
    ) -> PaneViewController? {
        guard let node = findLeaf(base) else { return nil }
        let newPane = makePane(workingDirectory: cwd ?? base.currentDirectory())
        // 対象の葉ノードをその場で「節」に変える (親ポインタを書き換えずに済む)。
        node.pane = nil
        node.direction = direction
        node.ratio = 0.5
        node.left = .leaf(base)
        node.right = .leaf(newPane)
        rebuild()
        newPane.focusTerminal()
        return newPane
    }

    // MARK: - IPC/CLI からのペイン生成

    /// 由来ペインを基点に新ペインを開く (`ghmux pane new` の実体)。`issueURL` を指定した場合のみ Issue をアサインする。
    /// origin が見つからなければアクティブペイン、それも無ければ先頭ペインへフォールバックする。
    /// - Returns: 開いた新ペインの ID。基点ペインが存在しなければ nil。
    @discardableResult
    func openPane(
        origin: String?,
        direction: IPC.Direction,
        cwd: String?,
        issueURL: String?
    ) -> String? {
        let base = origin.flatMap { pane(withId: $0) } ?? activePane() ?? collectPanes().first
        guard let base else { return nil }
        let splitDirection: BinarySplitView.Direction = (direction == .down) ? .vertical : .horizontal
        guard let newPane = splitFrom(base, direction: splitDirection, cwd: cwd) else { return nil }
        if let issueURL { newPane.assignIssue(urlString: issueURL) }
        return newPane.paneId
    }

    // MARK: - IPC/CLI 用スナップショット / 読み取り / クローズ

    /// このワークスペース内の全ペインのスナップショット (`ghmux pane list` 用)。
    func paneSnapshots() -> [IPC.PaneInfo] {
        let active = activePane()
        return collectPanes().map { pane in
            let gh = pane.githubSnapshot()
            return IPC.PaneInfo(
                paneId: pane.paneId,
                workingDirectory: pane.currentDirectory(),
                active: pane === active,
                issue: gh.issue,
                pullRequests: gh.pullRequests)
        }
    }

    /// 指定 ID のペインの端末内容を読み取る (`ghmux pane view` 用)。見つからなければ nil。
    func readPaneText(paneId: String, fullScreen: Bool) -> String? {
        pane(withId: paneId)?.readTerminalText(fullScreen: fullScreen)
    }

    /// 指定 ID のペインへ文字列を送る (`ghmux pane send` 用)。見つからなければ false。
    @discardableResult
    func sendToPane(paneId: String, text: String, submit: Bool) -> Bool {
        guard let pane = pane(withId: paneId) else { return false }
        pane.sendText(text, submit: submit)
        return true
    }

    /// 指定 ID のペインを閉じる (`ghmux pane close` 用)。
    /// 最後の 1 枚 or ID 不在なら false (`closePane(_:)` と同じく最後のペインは残す)。
    @discardableResult
    func closePane(withId id: String) -> Bool {
        guard collectPanes().count > 1, let target = pane(withId: id) else { return false }
        root = remove(target, from: root) ?? root
        rebuild()
        collectPanes().first?.focusTerminal()
        return true
    }

    // MARK: - ドラッグでのペイン再配置

    /// ヘッダドラッグでペイン移動を開始する。ペインが 1 枚だけなら何もしない。
    private func beginPaneDrag(_ pane: PaneViewController?, event: NSEvent) {
        guard let pane, collectPanes().count > 1 else { return }
        draggingPaneId = pane.paneId
        let item = NSPasteboardItem()
        item.setString(pane.paneId, forType: .ghmuxPane)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(pane.view.bounds, contents: pane.view.snapshotImage())
        pane.view.beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    /// ドラッグ元ペインを対象ペインの指定端へ移動して再分割する。
    /// 安全な順序: ツリーから外す → 対象葉を取得 → その場で節へ変換 → 一度だけ rebuild。
    /// detach と insert の間に rebuild を挟まないことで、ドラッグ元 VC が子から外れず
    /// ターミナル (スクロールバック含む) が維持される。
    @discardableResult
    func movePane(_ draggedId: String, ontoEdgeOf targetId: String, edge: PaneDropOverlayView.Edge) -> Bool {
        guard edge != .none,
              let dragged = pane(withId: draggedId),
              let target = pane(withId: targetId),
              dragged !== target else { return false }
        // 1) ドラッグ元をツリーから外す (旧親は兄弟に畳まれる)。rebuild はまだ呼ばない。
        root = remove(dragged, from: root) ?? root
        // 2) 対象葉を取得 (remove 後。ドラッグ元と兄弟だった場合も target は葉として残る)。
        guard let node = findLeaf(target) else { return false }
        let dir: BinarySplitView.Direction = (edge == .left || edge == .right) ? .horizontal : .vertical
        let draggedLeaf = SplitNode.leaf(dragged)
        node.pane = nil
        node.direction = dir
        node.ratio = 0.5
        if edge == .left || edge == .top {
            node.left = draggedLeaf
            node.right = .leaf(target)
        } else {
            node.left = .leaf(target)
            node.right = draggedLeaf
        }
        rebuild()
        dragged.focusTerminal()
        return true
    }

    /// ドラッグ中のみドロップ先オーバーレイを表示する。ドラッグ元自身は除外する。
    private func setDropOverlays(active: Bool, excluding draggedId: String?) {
        for pane in collectPanes() {
            pane.dropOverlay.isHidden = !active || (pane.paneId == draggedId)
        }
    }

    // MARK: - 閉じる

    @objc func closePane(_ sender: Any?) {
        guard collectPanes().count > 1, let active = activePane() else { return }
        root = remove(active, from: root) ?? root
        rebuild()
        collectPanes().first?.focusTerminal()
    }

    /// target を除去し、節は片側だけ残ったら兄弟で置き換える。
    private func remove(_ target: PaneViewController, from node: SplitNode) -> SplitNode? {
        if node.isLeaf {
            return node.pane === target ? nil : node
        }
        let l = node.left.flatMap { remove(target, from: $0) }
        let r = node.right.flatMap { remove(target, from: $0) }
        if l == nil { return r }
        if r == nil { return l }
        node.left = l
        node.right = r
        return node
    }

    // MARK: - フォーカス移動

    @objc func focusNextPane(_ sender: Any?) { cycleFocus(by: 1) }
    @objc func focusPreviousPane(_ sender: Any?) { cycleFocus(by: -1) }

    private func cycleFocus(by delta: Int) {
        let list = collectPanes()
        guard !list.isEmpty else { return }
        let active = activePane()
        let current = active.flatMap { a in list.firstIndex(where: { $0 === a }) } ?? 0
        let next = (current + delta + list.count) % list.count
        list[next].focusTerminal()
    }
}

// MARK: - NSDraggingSource (ペイン再配置)

extension WorkspaceViewController: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        setDropOverlays(active: true, excluding: draggingPaneId)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        setDropOverlays(active: false, excluding: nil)
        draggingPaneId = nil
    }
}
