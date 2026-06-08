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

/// CONCEPT.md の「Issue1 / PR1 CI Pass」相当のヘッダ表示。
/// Issue URL 入力欄 + Issue タイトル + PR リンク + CI バッジ。
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
    private let issueBadge = NSTextField(labelWithString: "")
    private let prLabel = LinkLabel(labelWithString: "PR: (none)")
    private let ciBadge = NSTextField(labelWithString: "")
    private let splitRightButton = NSButton()
    private let splitDownButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor

        issueField.placeholderString = "Paste a GitHub Issue URL and press Return"
        issueField.font = NSFont.systemFont(ofSize: 12)
        issueField.bezelStyle = .roundedBezel
        issueField.delegate = self
        issueField.translatesAutoresizingMaskIntoConstraints = false

        issueTitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        issueTitleLabel.textColor = NSColor.labelColor
        issueTitleLabel.lineBreakMode = .byTruncatingTail
        // 長いタイトルはバッジを押し出さず省略させる (バッジの右寄せを優先)。
        issueTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        issueTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        prLabel.font = NSFont.systemFont(ofSize: 11)
        prLabel.textColor = NSColor.secondaryLabelColor
        prLabel.translatesAutoresizingMaskIntoConstraints = false

        // バッジは最小幅 + 左揃えで、状態文字列の長短によらず先頭の記号位置を揃える。
        ciBadge.font = NSFont.systemFont(ofSize: 13)
        ciBadge.textColor = NSColor.tertiaryLabelColor
        ciBadge.alignment = .left
        ciBadge.translatesAutoresizingMaskIntoConstraints = false

        issueBadge.font = NSFont.systemFont(ofSize: 13)
        issueBadge.textColor = NSColor.tertiaryLabelColor
        issueBadge.alignment = .left
        issueBadge.translatesAutoresizingMaskIntoConstraints = false

        configureSplitButton(splitRightButton, symbol: "square.split.2x1", tip: "Split Right",
                             action: #selector(didTapSplitRight))
        configureSplitButton(splitDownButton, symbol: "square.split.1x2", tip: "Split Down",
                             action: #selector(didTapSplitDown))

        addSubview(issueField)
        addSubview(issueTitleLabel)
        addSubview(issueBadge)
        addSubview(prLabel)
        addSubview(ciBadge)
        addSubview(splitRightButton)
        addSubview(splitDownButton)

        // 状態バッジの最小幅。最長文字列 ("🟣 Closed" / "✅ Merged") が収まり、
        // 記号 (先頭) が常に同じ x 位置に来る幅。両バッジで共有して列を揃える。
        let badgeMinWidth: CGFloat = 80

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
            issueBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: badgeMinWidth),

            // PR 行 (PR リンク + 状態/CI バッジ)。
            prLabel.topAnchor.constraint(equalTo: issueTitleLabel.bottomAnchor, constant: 2),
            prLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),

            ciBadge.centerYAnchor.constraint(equalTo: prLabel.centerYAnchor),
            ciBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            ciBadge.leadingAnchor.constraint(greaterThanOrEqualTo: prLabel.trailingAnchor, constant: 8),
            ciBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: badgeMinWidth),
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

    /// PR をクリック可能なリンクとして表示する (番号のみ。状態はステータスバッジへ集約)。
    func showPR(number: Int, url: URL) {
        prLabel.setLink("PR #\(number)", url: url)
    }

    /// PR を探索中であることを示す。
    func showPRSearching() {
        prLabel.setLink("PR を探索中…", url: nil)
        ciBadge.stringValue = ""
    }

    /// PR 探索のエラーを示す (gh 失敗など)。
    func showPRError(_ message: String) {
        prLabel.setLink("PR 探索エラー: \(message)", url: nil)
        ciBadge.stringValue = ""
    }

    /// PR 状態と CI を 1 つのステータスバッジに統合して表示する。
    /// マージ/クローズ済みなら CI は出さず、その状態だけを示す。open のときのみ CI を示す。
    func showStatus(prState: GitHub.PullRequest.State, ci: GitHub.CIStatus) {
        switch prState {
        case .merged:
            ciBadge.stringValue = "✅ Merged"
            ciBadge.toolTip = "Merged"
        case .closed:
            ciBadge.stringValue = "🚫 Closed"
            ciBadge.toolTip = "Closed without merge"
        case .open:
            switch ci {
            case .noChecks:
                ciBadge.stringValue = ""
                ciBadge.toolTip = nil
            case .pending:
                ciBadge.stringValue = "🟡 CI"
                ciBadge.toolTip = "CI running"
            case .success:
                ciBadge.stringValue = "✅ CI"
                ciBadge.toolTip = "CI passed"
            case .failure(let jobs):
                ciBadge.stringValue = "❌ CI"
                ciBadge.toolTip = "CI failed: " + jobs.joined(separator: ", ")
            }
        }
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
