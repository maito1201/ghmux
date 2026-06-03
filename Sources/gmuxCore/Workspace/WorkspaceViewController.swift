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

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = v

        let p = makePane()
        root = .leaf(p)
        rebuild()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        collectPanes().first?.focusTerminal()
    }

    // MARK: - 生成

    private func makePane(workingDirectory: String? = nil) -> PaneViewController {
        PaneViewController(workingDirectory: workingDirectory)
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
        guard let active = activePane(), let node = findLeaf(active) else { return }
        // アクティブペインの作業ディレクトリを引き継いで新ペインを作る (cmux/ghostty と同挙動)。
        let newPane = makePane(workingDirectory: active.currentDirectory())
        // 対象の葉ノードをその場で「節」に変える (親ポインタを書き換えずに済む)。
        node.pane = nil
        node.direction = direction
        node.ratio = 0.5
        node.left = .leaf(active)
        node.right = .leaf(newPane)
        rebuild()
        newPane.focusTerminal()
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
