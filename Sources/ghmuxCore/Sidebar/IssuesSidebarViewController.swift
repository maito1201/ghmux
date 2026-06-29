import AppKit

/// 画面左端に常駐する Issue 一覧サイドバー。
///
/// config の `[issues].repositories` のリポジトリについて、自分にアサインされた Open Issue を
/// 一覧表示する。タイトルは `LinkLabel` (PaneHeaderView と共有) でリンク化し、クリックで
/// 既定ブラウザに開く。自動リロードはせず、上部の更新ボタンで再取得する。
/// 上部の開閉ボタンで最小化できる。
final class IssuesSidebarViewController: NSViewController {

    /// スクロール領域の documentView。左上原点にして最上部から表示する。
    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    private static let expandedWidth: CGFloat = 280
    private static let collapsedWidth: CGFloat = 32

    private let repositories: [String]
    private let client = GitHubClient()

    private(set) var isCollapsed = false
    private var widthConstraint: NSLayoutConstraint!

    private let titleLabel = NSTextField(labelWithString: "Issues")
    private let refreshButton = NSButton()
    private let toggleButton = NSButton()
    private let scrollView = NSScrollView()
    private let listStack = NSStackView()

    private var fetchTask: Task<Void, Never>?

    init(repositories: [String]) {
        self.repositories = repositories
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(repositories:)") }

    deinit { fetchTask?.cancel() }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        // 背景が常にダークなので、ライトモードでも文字/アイコンが見えるよう固定する。
        root.appearance = NSAppearance(named: .darkAqua)
        view = root

        widthConstraint = root.widthAnchor.constraint(equalToConstant: Self.expandedWidth)
        widthConstraint.isActive = true

        configureHeader()
        configureList()

        let guide = root.safeAreaLayoutGuide

        // トグル(開閉)ボタンは常に見える必要があるため、位置は必須制約で固定する。
        // leading も持たせ、最小化幅(32px)でも他制約に押し出されないようにする。
        let toggleConstraints = [
            toggleButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            toggleButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            toggleButton.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 6),
            toggleButton.widthAnchor.constraint(equalToConstant: 18),
            toggleButton.heightAnchor.constraint(equalToConstant: 18),
        ]
        NSLayoutConstraint.activate(toggleConstraints)

        // タイトル/更新ボタンは展開時のみ収まる。最小化幅では両立不能になるので、
        // 必須より低い優先度にして「狭いときは黙って破棄」させ、トグルの位置を守る。
        let optionalHeader = [
            refreshButton.centerYAnchor.constraint(equalTo: toggleButton.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: toggleButton.leadingAnchor, constant: -6),
            refreshButton.widthAnchor.constraint(equalToConstant: 18),
            refreshButton.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.centerYAnchor.constraint(equalTo: toggleButton.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -6),
        ]
        for c in optionalHeader { c.priority = .defaultHigh }
        NSLayoutConstraint.activate(optionalHeader)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: toggleButton.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private func configureHeader() {
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        configureIconButton(refreshButton, symbol: "arrow.clockwise", tip: "Reload issues",
                            action: #selector(didTapRefresh))
        configureIconButton(toggleButton, symbol: "chevron.left", tip: "Collapse",
                            action: #selector(didTapToggle))

        view.addSubview(titleLabel)
        view.addSubview(refreshButton)
        view.addSubview(toggleButton)
    }

    private func configureList() {
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 4
        listStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let doc = FlippedDocument()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack)
        scrollView.documentView = doc
        view.addSubview(scrollView)

        // SettingsViewController と同じ動作実績パターン:
        // documentView を clip(contentView) の leading/trailing/top に固定して位置と幅を確定し、
        // stack が doc の高さを決める (doc.bottom は固定しない)。横スクロールも防げる。
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),

            listStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 8),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 10),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -10),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -8),
        ])
    }

    private func configureIconButton(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = NSColor.secondaryLabelColor
        button.toolTip = tip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    // MARK: - 開閉

    @objc private func didTapToggle(_ sender: Any?) {
        isCollapsed.toggle()
        let collapsed = isCollapsed
        toggleButton.image = NSImage(
            systemSymbolName: collapsed ? "chevron.right" : "chevron.left",
            accessibilityDescription: collapsed ? "Expand" : "Collapse")
        toggleButton.toolTip = collapsed ? "Expand" : "Collapse"
        titleLabel.isHidden = collapsed
        refreshButton.isHidden = collapsed
        scrollView.isHidden = collapsed

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            widthConstraint.animator().constant = collapsed ? Self.collapsedWidth : Self.expandedWidth
            view.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - フェッチ

    @objc private func didTapRefresh(_ sender: Any?) { reload() }

    func reload() {
        fetchTask?.cancel()
        showStatus("Loading…")
        let repos = repositories
        let client = client
        fetchTask = Task { [weak self] in
            var sections: [(repo: String, issues: [GitHub.Issue]?, error: String?)] = []
            for repo in repos {
                if Task.isCancelled { return }
                do {
                    let issues = try await client.fetchAssignedOpenIssues(repo: repo)
                    sections.append((repo, issues, nil))
                } catch {
                    sections.append((repo, nil, Self.describe(error)))
                }
            }
            if Task.isCancelled { return }
            await MainActor.run { self?.render(sections) }
        }
    }

    private static func describe(_ error: Swift.Error) -> String {
        if let e = error as? GitHubClient.Error {
            switch e {
            case .ghFailed(_, let stderr):
                let s = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? "gh の実行に失敗しました" : s
            case .decode: return "応答の解析に失敗しました"
            case .invalidURL: return "URL が不正です"
            }
        }
        return String(describing: error)
    }

    // MARK: - 描画 (main thread)

    private func clearList() {
        for v in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    private func showStatus(_ message: String) {
        clearList()
        listStack.addArrangedSubview(makeStatusLabel(message))
    }

    private func render(_ sections: [(repo: String, issues: [GitHub.Issue]?, error: String?)]) {
        clearList()
        let hasAnyIssue = sections.contains { ($0.issues?.isEmpty == false) }
        let hasAnyError = sections.contains { $0.error != nil }
        if !hasAnyIssue && !hasAnyError {
            listStack.addArrangedSubview(makeStatusLabel("アサインされた Open Issue はありません"))
            return
        }
        for section in sections {
            listStack.addArrangedSubview(makeSectionHeader(section.repo))
            if let error = section.error {
                listStack.addArrangedSubview(makeStatusLabel("⚠️ \(error)"))
            } else if let issues = section.issues, !issues.isEmpty {
                for issue in issues {
                    listStack.addArrangedSubview(makeIssueRow(issue))
                }
            } else {
                listStack.addArrangedSubview(makeStatusLabel("なし"))
            }
        }
    }

    private func makeSectionHeader(_ repo: String) -> NSView {
        let label = NSTextField(labelWithString: repo)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor.tertiaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeIssueRow(_ issue: GitHub.Issue) -> NSView {
        let link = LinkLabel(labelWithString: "")
        link.font = NSFont.systemFont(ofSize: 12)
        link.lineBreakMode = .byTruncatingTail
        link.usesSingleLineMode = true
        link.maximumNumberOfLines = 1
        link.translatesAutoresizingMaskIntoConstraints = false
        link.setLink("#\(issue.number) \(issue.title)", url: issue.url)
        return link
    }

    private func makeStatusLabel(_ message: String) -> NSView {
        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = NSColor.secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.toolTip = message
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
