import AppKit

/// ghmux の設定ウィンドウ (Cmd+,)。TOML を手編集せず、フォームで設定を編集・保存する。
/// 保存すると `~/.config/ghmux/config.toml` に書き出し、以後作られるペインに反映される。
public final class SettingsWindowController: NSWindowController {

    public convenience init() {
        let vc = SettingsViewController()
        let window = NSWindow(contentViewController: vc)
        window.title = "ghmux 設定"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 820))
        window.minSize = NSSize(width: 520, height: 560)
        window.center()
        self.init(window: window)
    }

    public func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 設定フォーム本体。
final class SettingsViewController: NSViewController {

    private let initialPromptView = SettingsViewController.makeTextView(height: 200)
    private let agentCommandField = NSTextField()
    private let intervalField = NSTextField()
    private let ciFailedView = SettingsViewController.makeTextView(height: 130)
    private let ciPassedView = SettingsViewController.makeTextView(height: 130)
    private let changesRequestedView = SettingsViewController.makeTextView(height: 130)
    private let commentedView = SettingsViewController.makeTextView(height: 130)
    private let mergeConflictView = SettingsViewController.makeTextView(height: 100)

    override func loadView() {
        let root = NSView()

        // --- スクロール可能なフォーム本体 ---
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        stack.addArrangedSubview(section(
            title: "初回プロンプト",
            help: "Issue URL を貼ったときエージェントへ渡す。プレースホルダ: {issue_url} {number} {title} {body}",
            field: initialPromptView.scroll))

        stack.addArrangedSubview(agentCommandSection())

        stack.addArrangedSubview(intervalSection())

        stack.addArrangedSubview(section(
            title: "CI 失敗時の自動プロンプト",
            help: "プレースホルダ: {url} {failingChecks}",
            field: ciFailedView.scroll))
        stack.addArrangedSubview(section(
            title: "CI Pass 時の自動プロンプト",
            help: "CI が「実行中→成功」または「失敗→再 run で成功」に変化したときのみ送信。プレースホルダ: {url}",
            field: ciPassedView.scroll))
        stack.addArrangedSubview(section(
            title: "修正リクエスト時の自動プロンプト",
            help: "プレースホルダ: {url} {reviewer} {body}",
            field: changesRequestedView.scroll))
        stack.addArrangedSubview(section(
            title: "コメント時の自動プロンプト",
            help: "プレースホルダ: {url} {reviewer} {body}",
            field: commentedView.scroll))
        stack.addArrangedSubview(section(
            title: "コンフリクト時の自動プロンプト",
            help: "プレースホルダ: {url}",
            field: mergeConflictView.scroll))

        // 各セクションを横幅いっぱいに伸ばす (NSStackView は perpendicular 方向に
        // arranged subview を伸ばさないため、明示的に幅を揃える)。
        for sectionView in stack.arrangedSubviews {
            sectionView.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                               constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc

        // --- 下部ボタンバー ---
        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}" // Esc
        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r" // Return
        let buttonBar = NSStackView(views: [NSView(), cancel, save])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 12
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scroll)
        root.addSubview(buttonBar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -8),

            buttonBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            buttonBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttonBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            // documentView を scroll の幅に合わせ、横スクロールを防ぐ。
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),

            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        view = root
        populate(from: GhmuxConfig.current)
    }

    // MARK: - フォーム構築ヘルパー

    /// (スクロール付き) 複数行テキストビュー。`height` で表示高さを指定。
    private static func makeTextView(height: CGFloat) -> (scroll: NSScrollView, text: NSTextView) {
        let text = NSTextView()
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return (scroll, text)
    }

    private func section(title: String, help: String, field: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let helpLabel = NSTextField(labelWithString: help)
        helpLabel.font = .systemFont(ofSize: 11)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.lineBreakMode = .byWordWrapping
        helpLabel.maximumNumberOfLines = 0

        let col = NSStackView(views: [titleLabel, helpLabel, field])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 4
        col.translatesAutoresizingMaskIntoConstraints = false
        // フィールドとヘルプをセクション幅いっぱいに伸ばす (テキストエリアを広く保つ)。
        field.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        helpLabel.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    private func agentCommandSection() -> NSView {
        let titleLabel = NSTextField(labelWithString: "エージェント起動コマンド")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let helpLabel = NSTextField(labelWithString: "{prompt} が初回プロンプトに置換される。例: claude {prompt} / codex {prompt}")
        helpLabel.font = .systemFont(ofSize: 11)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.lineBreakMode = .byWordWrapping
        helpLabel.maximumNumberOfLines = 0
        agentCommandField.translatesAutoresizingMaskIntoConstraints = false
        agentCommandField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let col = NSStackView(views: [titleLabel, helpLabel, agentCommandField])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 4
        col.translatesAutoresizingMaskIntoConstraints = false
        agentCommandField.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        helpLabel.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    private func intervalSection() -> NSView {
        let titleLabel = NSTextField(labelWithString: "PR / CI ポーリング間隔（秒）")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        intervalField.translatesAutoresizingMaskIntoConstraints = false
        intervalField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let col = NSStackView(views: [titleLabel, intervalField])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 4
        return col
    }

    // MARK: - 値の出し入れ

    private func populate(from config: GhmuxConfig) {
        initialPromptView.text.string = config.initialPrompt
        agentCommandField.stringValue = config.agentCommand
        intervalField.stringValue = String(config.pollIntervalSeconds)
        ciFailedView.text.string = config.autoPrompts.ciFailed
        ciPassedView.text.string = config.autoPrompts.ciPassed
        changesRequestedView.text.string = config.autoPrompts.changesRequested
        commentedView.text.string = config.autoPrompts.commented
        mergeConflictView.text.string = config.autoPrompts.mergeConflict
    }

    private func buildConfig() -> GhmuxConfig {
        let interval = Int(intervalField.stringValue.trimmingCharacters(in: .whitespaces))
            ?? GhmuxConfig.current.pollIntervalSeconds
        let cmd = agentCommandField.stringValue.trimmingCharacters(in: .whitespaces)
        return GhmuxConfig(
            initialPrompt: initialPromptView.text.string,
            agentCommand: cmd.isEmpty ? GhmuxConfig.default.agentCommand : cmd,
            pollIntervalSeconds: max(1, interval),
            autoPrompts: .init(
                ciFailed: ciFailedView.text.string,
                ciPassed: ciPassedView.text.string,
                changesRequested: changesRequestedView.text.string,
                commented: commentedView.text.string,
                mergeConflict: mergeConflictView.text.string
            )
        )
    }

    // MARK: - アクション

    @objc private func save() {
        do {
            try buildConfig().save()
            view.window?.close()
        } catch {
            let alert = NSAlert()
            alert.messageText = "設定の保存に失敗しました"
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func cancel() {
        view.window?.close()
    }
}
