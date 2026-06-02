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

    private let issueField = PasteableTextField()
    private let issueTitleLabel = LinkLabel(labelWithString: "")
    private let prLabel = LinkLabel(labelWithString: "PR: (none)")
    private let ciBadge = NSTextField(labelWithString: "")

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
        issueTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        prLabel.font = NSFont.systemFont(ofSize: 11)
        prLabel.textColor = NSColor.secondaryLabelColor
        prLabel.translatesAutoresizingMaskIntoConstraints = false

        ciBadge.font = NSFont.systemFont(ofSize: 13)
        ciBadge.textColor = NSColor.tertiaryLabelColor
        ciBadge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(issueField)
        addSubview(issueTitleLabel)
        addSubview(prLabel)
        addSubview(ciBadge)

        NSLayoutConstraint.activate([
            issueField.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            issueField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            issueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            issueTitleLabel.topAnchor.constraint(equalTo: issueField.bottomAnchor, constant: 4),
            issueTitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            issueTitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            prLabel.topAnchor.constraint(equalTo: issueTitleLabel.bottomAnchor, constant: 2),
            prLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),

            ciBadge.centerYAnchor.constraint(equalTo: prLabel.centerYAnchor),
            ciBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            ciBadge.leadingAnchor.constraint(greaterThanOrEqualTo: prLabel.trailingAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    // MARK: - 表示更新 (すべて main thread から呼ぶ)

    /// Issue をクリック可能なリンクとして表示する。
    func showIssue(title: String, number: Int, url: URL) {
        issueTitleLabel.setLink("#\(number) \(title)", url: url)
    }

    func showIssueError(_ message: String) {
        issueTitleLabel.setLink("⚠️ \(message)", url: nil)
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
