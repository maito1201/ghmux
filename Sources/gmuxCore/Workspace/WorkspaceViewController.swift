import AppKit

/// 複数 `PaneViewController` を分割表示するコンテナ。
/// Phase 0 では 1 ペインのみ。Phase 3 で `NSSplitView` ネストにより 2x2 分割対応。
final class WorkspaceViewController: NSViewController {

    private let stackView = NSStackView()
    private var panes: [PaneViewController] = []

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        stackView.orientation = .vertical
        stackView.distribution = .fill
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: root.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
        addPane()
    }

    @discardableResult
    private func addPane() -> PaneViewController {
        let pane = PaneViewController()
        addChild(pane)
        stackView.addArrangedSubview(pane.view)
        // 縦 NSStackView は arranged subview を幅方向に引き伸ばさない。
        // 明示的に stackView 幅へピン留めしないとペインが固有幅 (狭い) に潰れる。
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        pane.view.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        panes.append(pane)
        return pane
    }
}
