import AppKit

/// Ctrl+V / Cmd+V でのペースト (および Cmd+C/X/A) を確実に処理するテキストフィールド。
/// macOS の既定では Ctrl+V は「ページダウン」に割り当てられ、ペーストにならないため、
/// `performKeyEquivalent` で明示的にハンドリングする。Edit メニューを持たない構成でも動く。
final class PasteableTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let editor = currentEditor(), // 編集中 (フォーカス) のときだけ処理
              let chars = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Ctrl+V または Cmd+V → ペースト
        if (flags == .control || flags == .command), chars == "v" {
            editor.paste(nil)
            return true
        }
        if flags == .command {
            switch chars {
            case "c": editor.copy(nil); return true
            case "x": editor.cut(nil); return true
            case "a": editor.selectAll(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// クリックで既定ブラウザに URL を開くラベル。URL 未設定時はただのラベルとして振る舞う。
final class LinkLabel: NSTextField {
    private(set) var url: URL?

    /// リンクとして表示する。`url` が nil ならプレーンテキスト。
    func setLink(_ text: String, url: URL?) {
        self.url = url
        if let url {
            attributedStringValue = NSAttributedString(string: text, attributes: [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .font: font ?? NSFont.systemFont(ofSize: 11),
            ])
            toolTip = url.absoluteString
        } else {
            attributedStringValue = NSAttributedString(string: text, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: font ?? NSFont.systemFont(ofSize: 11),
            ])
            toolTip = nil
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        if url != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        if let url { NSWorkspace.shared.open(url) } else { super.mouseDown(with: event) }
    }
}

/// PR 1 件分の行 (クリック可能な PR リンク + 状態/CI バッジ)。
/// 1 Issue : N PR を縦に積めるよう、ヘッダ内のスタックに並べて使う。
final class PRStatusRow: NSView {

    /// 状態バッジの最小幅。最長文字列 ("🚫 Closed" / "✅ Merged") が収まり、
    /// 先頭の記号が常に同じ x 位置に来る幅。Issue バッジと共有して列を揃える。
    static let badgeMinWidth: CGFloat = 80

    /// バッジ用 NSTextField を共通スタイルで生成する (Issue / PR で見た目を揃える)。
    static func makeBadge() -> NSTextField {
        let badge = NSTextField(labelWithString: "")
        badge.font = NSFont.systemFont(ofSize: 13)
        badge.textColor = NSColor.tertiaryLabelColor
        badge.alignment = .left
        badge.translatesAutoresizingMaskIntoConstraints = false
        return badge
    }

    private let link = LinkLabel(labelWithString: "")
    private let badge = PRStatusRow.makeBadge()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        link.font = NSFont.systemFont(ofSize: 11)
        link.textColor = NSColor.secondaryLabelColor
        link.lineBreakMode = .byTruncatingTail
        // 長いリンク文字でもバッジを押し出さず省略させ、バッジの右寄せを優先する。
        link.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        link.translatesAutoresizingMaskIntoConstraints = false

        addSubview(link)
        addSubview(badge)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            link.leadingAnchor.constraint(equalTo: leadingAnchor),
            link.centerYAnchor.constraint(equalTo: centerYAnchor),

            // バッジは行右端固定 + 最小幅で、状態文字列の長短によらず記号位置を揃える。
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: link.trailingAnchor, constant: 8),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.badgeMinWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    /// PR をクリック可能なリンクとして表示する (番号のみ。状態はバッジへ集約)。
    func showLink(number: Int, url: URL?) {
        link.setLink("PR #\(number)", url: url)
    }

    /// 探索中/エラー等のメッセージを表示する (バッジは消す)。
    func showMessage(_ text: String) {
        link.setLink(text, url: nil)
        badge.stringValue = ""
        badge.toolTip = nil
    }

    /// PR 状態と CI を 1 つのバッジに統合して表示する。
    /// マージ/クローズ済みなら CI は出さず、その状態だけを示す。open のときのみ CI を示す。
    func showStatus(prState: GitHub.PullRequest.State, ci: GitHub.CIStatus) {
        switch prState {
        case .merged:
            badge.stringValue = "🟣 Merged"
            badge.toolTip = "Merged"
        case .closed:
            badge.stringValue = "🔴 Closed"
            badge.toolTip = "Closed without merge"
        case .open:
            switch ci {
            case .noChecks:
                badge.stringValue = ""
                badge.toolTip = nil
            case .pending:
                badge.stringValue = "🟡 CI"
                badge.toolTip = "CI running"
            case .success:
                badge.stringValue = "✅ CI"
                badge.toolTip = "CI passed"
            case .failure(let jobs):
                badge.stringValue = "❌ CI"
                badge.toolTip = "CI failed: " + jobs.joined(separator: ", ")
            }
        }
    }
}

/// CONCEPT.md の「Issue1 / PR1 CI Pass」相当のヘッダ表示。
/// Issue URL 入力欄 + Issue タイトル/状態 + (1 Issue : N の) PR リンク/状態行。
final class PaneHeaderView: NSView, NSTextFieldDelegate {

    /// Issue URL が入力 (Return) されたときに呼ばれる。
    var onSubmitIssueURL: ((String) -> Void)?
    /// 右上の分割ボタンが押されたとき (このペインを左右/上下に分割する)。
    var onSplitRight: (() -> Void)?
    var onSplitDown: (() -> Void)?
    /// ヘッダ背景をドラッグし始めたとき (ペイン再配置のドラッグ開始)。
    var onBeginPaneDrag: ((NSEvent) -> Void)?

    private let issueField = PasteableTextField()
    private let issueTitleLabel = LinkLabel(labelWithString: "")
    private let issueBadge = PRStatusRow.makeBadge()
    /// PR 行を縦に積むスタック (1 Issue : N PR)。
    private let prStack = NSStackView()
    /// PR が 1 件も無いときに探索中/エラーを出す常設行。
    private let placeholderRow = PRStatusRow()
    /// PR URL → 行。GitHub 上の紐付け集合に追従して増減する。
    private var prRows: [URL: PRStatusRow] = [:]
    private let splitRightButton = NSButton()
    private let splitDownButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor

        issueField.placeholderString = "Paste a GitHub Issue or PR URL and press Return"
        issueField.font = NSFont.systemFont(ofSize: 12)
        issueField.bezelStyle = .roundedBezel
        issueField.delegate = self
        issueField.translatesAutoresizingMaskIntoConstraints = false

        issueTitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        issueTitleLabel.textColor = NSColor.labelColor
        issueTitleLabel.lineBreakMode = .byTruncatingTail
        // 単一行に固定し、横幅が縮んでも折り返さず省略する (折り返すと PR 行が下へ押し出され見切れる)。
        issueTitleLabel.usesSingleLineMode = true
        issueTitleLabel.maximumNumberOfLines = 1
        // 長いタイトルはバッジを押し出さず省略させる (バッジの右寄せを優先)。
        issueTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        issueTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // PR 行スタック。各行は幅をスタックに合わせて右端バッジ列を揃える (rowForPR で width 制約)。
        prStack.orientation = .vertical
        prStack.alignment = .leading
        prStack.spacing = 2
        prStack.translatesAutoresizingMaskIntoConstraints = false
        prStack.addArrangedSubview(placeholderRow)

        configureSplitButton(splitRightButton, symbol: "square.split.2x1", tip: "Split Right",
                             action: #selector(didTapSplitRight))
        configureSplitButton(splitDownButton, symbol: "square.split.1x2", tip: "Split Down",
                             action: #selector(didTapSplitDown))

        addSubview(issueField)
        addSubview(issueTitleLabel)
        addSubview(issueBadge)
        addSubview(prStack)
        addSubview(splitRightButton)
        addSubview(splitDownButton)

        NSLayoutConstraint.activate([
            issueField.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            issueField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            issueField.trailingAnchor.constraint(equalTo: splitRightButton.leadingAnchor, constant: -6),

            // 分割ボタンは row1 のトップ行に右寄せ。issueField はその左で止める。
            splitDownButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            splitDownButton.centerYAnchor.constraint(equalTo: issueField.centerYAnchor),
            splitDownButton.widthAnchor.constraint(equalToConstant: 18),
            splitDownButton.heightAnchor.constraint(equalToConstant: 18),

            splitRightButton.trailingAnchor.constraint(equalTo: splitDownButton.leadingAnchor, constant: -4),
            splitRightButton.centerYAnchor.constraint(equalTo: issueField.centerYAnchor),
            splitRightButton.widthAnchor.constraint(equalToConstant: 18),
            splitRightButton.heightAnchor.constraint(equalToConstant: 18),

            // Issue 行 (タイトル + 状態バッジ)。PR 行と同じ「ラベルは leading 固定 /
            // バッジは trailing 固定 + leading >= ラベル trailing」パターンで右寄せする。
            issueTitleLabel.topAnchor.constraint(equalTo: issueField.bottomAnchor, constant: 4),
            issueTitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),

            issueBadge.centerYAnchor.constraint(equalTo: issueTitleLabel.centerYAnchor),
            issueBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            issueBadge.leadingAnchor.constraint(greaterThanOrEqualTo: issueTitleLabel.trailingAnchor, constant: 8),
            issueBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: PRStatusRow.badgeMinWidth),

            // PR 行スタック。bottom を自身の下端へ固定し、ヘッダ高さを内容に追従させる
            // (固定高をやめることで PR 行が増えても見切れない)。
            prStack.topAnchor.constraint(equalTo: issueTitleLabel.bottomAnchor, constant: 4),
            prStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            prStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            prStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            placeholderRow.widthAnchor.constraint(equalTo: prStack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    // MARK: - 分割ボタン

    private func configureSplitButton(_ button: NSButton, symbol: String, tip: String, action: Selector) {
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

    @objc private func didTapSplitRight(_ sender: Any?) { onSplitRight?() }
    @objc private func didTapSplitDown(_ sender: Any?) { onSplitDown?() }

    // MARK: - ペイン再配置のドラッグ開始

    /// ヘッダ背景のドラッグでペイン移動を開始する。
    /// 入力欄/ラベル/ボタンは各サブビューが mouseDown を吸収するため、ここには届かない。
    /// mouseDragged を受け取るには mouseDown を受理する必要がある (DividerView と同様)。
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        onBeginPaneDrag?(event)
    }

    // MARK: - 表示更新 (すべて main thread から呼ぶ)

    /// Issue をクリック可能なリンクとして表示する。
    func showIssue(title: String, number: Int, url: URL) {
        issueTitleLabel.setLink("#\(number) \(title)", url: url)
    }

    func showIssueError(_ message: String) {
        issueTitleLabel.setLink("⚠️ \(message)", url: nil)
        issueBadge.stringValue = ""
        issueBadge.toolTip = nil
    }

    /// PR を直接投入したときのヘッドライン (上部のタイトル行に PR をリンク表示)。
    /// 紐づく Issue が無いので Issue バッジは消す。CI/状態は下の PR 行 (updatePR) が担う。
    func showPRHeadline(title: String, number: Int, url: URL) {
        issueTitleLabel.setLink("#\(number) \(title)", url: url)
        issueBadge.stringValue = ""
        issueBadge.toolTip = nil
    }

    /// Issue の Open/Close 状態をタイトル行右端のバッジに表示する。
    func showIssueStatus(state: GitHub.Issue.State) {
        switch state {
        case .open:
            issueBadge.stringValue = "🟢 Open"
            issueBadge.toolTip = "Issue open"
        case .closed:
            issueBadge.stringValue = "🟣 Closed"
            issueBadge.toolTip = "Issue closed"
        }
    }

    // MARK: - PR 行 (1 Issue : N PR)

    /// PR を探索中であることを示す (PR 行が 1 件も無い状態)。
    func showPRSearching() {
        clearPRRows()
        placeholderRow.isHidden = false
        placeholderRow.showMessage("PR を探索中…")
    }

    /// PR 探索のエラーを示す (gh 失敗など)。
    /// 既に PR 行があるなら、一過性の失敗で消さないようエラーは出さない。
    func showPRError(_ message: String) {
        guard prRows.isEmpty else { return }
        placeholderRow.isHidden = false
        placeholderRow.showMessage("PR 探索エラー: \(message)")
    }

    /// 指定 URL の PR 行を用意する (無ければ作る)。URL から番号を取り即時にリンク表示する。
    /// 状態は後続の `updatePR` (watcher 由来) で埋まる。
    func ensurePR(url: URL) {
        let row = rowForPR(url)
        if let number = try? GitHubClient.parsePRUrl(url).number {
            row.showLink(number: number, url: url)
        }
        placeholderRow.isHidden = true
    }

    /// PR の状態/CI をその行に反映する。
    func updatePR(url: URL, number: Int, state: GitHub.PullRequest.State, ci: GitHub.CIStatus) {
        let row = rowForPR(url)
        row.showLink(number: number, url: url)
        row.showStatus(prState: state, ci: ci)
        placeholderRow.isHidden = true
    }

    /// GitHub 上の紐付けが解消された PR 行を取り除く。残り 0 件なら探索中表示へ戻す。
    func removePR(url: URL) {
        if let row = prRows.removeValue(forKey: url) {
            prStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        if prRows.isEmpty { showPRSearching() }
    }

    /// URL に対応する PR 行を返す (無ければ生成してスタックへ追加)。
    private func rowForPR(_ url: URL) -> PRStatusRow {
        if let row = prRows[url] { return row }
        let row = PRStatusRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        prStack.addArrangedSubview(row)
        // 行幅をスタック幅に合わせ、各行のバッジ右端を揃える。
        row.widthAnchor.constraint(equalTo: prStack.widthAnchor).isActive = true
        prRows[url] = row
        return row
    }

    private func clearPRRows() {
        for (_, row) in prRows {
            prStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        prRows.removeAll()
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let text = issueField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onSubmitIssueURL?(text) }
            return true
        }
        return false
    }
}
