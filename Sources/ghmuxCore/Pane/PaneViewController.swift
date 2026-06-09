import AppKit
import Ghostty
import os

private let log = Logger(subsystem: "com.ghmux.core", category: "pane")

/// 1 ペイン = ヘッダ(Issue / PR) + ターミナル領域 (libghostty Surface)。
///
/// CONCEPT のコアフローを束ねるコーディネータ:
///   Issue URL 入力 → GitHubClient.fetchIssue → ヘッダ描画 → ClaudeSession 起動
///   → 定期的に Issue を参照する PR を探索 → 発見後 PullRequestWatcher で CI を監視
///   → 状態変化を AutoPromptRules でプロンプト化し ClaudeSession へ送信。
final class PaneViewController: NSViewController {

    private let header = PaneHeaderView()
    private let terminalHost: TerminalHostView
    /// ドラッグ中だけ表示するドロップ先オーバーレイ。
    let dropOverlay = PaneDropOverlayView()

    /// 分割ボタン/ヘッダドラッグの要求を WorkspaceViewController へ中継するクロージャ。
    /// (ペイン自身は親ワークスペースを参照しない。Workspace が makePane 時に注入する)
    var onRequestSplitRight: (() -> Void)?
    var onRequestSplitDown: (() -> Void)?
    var onRequestBeginDrag: ((NSEvent) -> Void)?

    /// このペインの一意な ID。CLI (`ghmux pane new`) が `GHMUX_PANE` で参照し、
    /// どのペインを分割元にするか GUI へ伝えるのに使う。
    let paneId: String

    /// `workingDirectory` を渡すと端末をそのディレクトリで起動する (分割時の cwd 引き継ぎ)。
    /// PTY には `GHMUX_PANE` (このペインの ID) と `GHMUX_SOCK` (IPC ソケットパス) を注入し、
    /// ペイン内で動く claude が `ghmux pane new` を叩けるようにする。
    init(workingDirectory: String? = nil, paneId: String = UUID().uuidString) {
        self.paneId = paneId
        let environment = [
            IPC.paneEnvKey: paneId,
            IPC.socketEnvKey: IPC.defaultSocketPath,
        ]
        self.terminalHost = TerminalHostView(
            workingDirectory: workingDirectory, environment: environment)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(workingDirectory:paneId:)") }

    private let client = GitHubClient()
    /// ユーザー設定 (~/.config/ghmux/config.toml)。
    private let config = GhmuxConfig.current
    private lazy var autoPromptRules = AutoPromptRules(config: config.autoPrompts)
    private var session: ClaudeSession?

    /// 監視ループのキャンセル用タスク。
    private var prDiscoveryTask: Task<Void, Never>?
    /// PR URL → 監視タスク。1 Issue : N PR を URL ごとに独立監視する。
    private var prWatchTasks: [URL: Task<Void, Never>] = [:]
    private var issueWatchTask: Task<Void, Never>?

    /// PR/CI 監視の間隔 (秒)。設定から取得。
    private lazy var pollInterval: UInt64 = UInt64(max(1, config.pollIntervalSeconds))

    override func loadView() {
        let root = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        dropOverlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(terminalHost)
        root.addSubview(dropOverlay) // 最前面 (ドラッグ中のみ表示)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // 高さは固定せず、ヘッダ内部の制約 (PR 行の本数) に追従させる。

            terminalHost.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminalHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            dropOverlay.topAnchor.constraint(equalTo: root.topAnchor),
            dropOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            dropOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dropOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        header.onSubmitIssueURL = { [weak self] urlString in
            self?.handleIssueSubmission(urlString)
        }
        header.onSplitRight = { [weak self] in self?.onRequestSplitRight?() }
        header.onSplitDown = { [weak self] in self?.onRequestSplitDown?() }
        header.onBeginPaneDrag = { [weak self] event in self?.onRequestBeginDrag?(event) }
        dropOverlay.paneId = paneId
        view = root
    }

    deinit {
        prDiscoveryTask?.cancel()
        prWatchTasks.values.forEach { $0.cancel() }
        issueWatchTask?.cancel()
    }

    /// 端末をキーボードフォーカスにする (分割直後・フォーカス移動時に呼ぶ)。
    func focusTerminal() {
        terminalHost.focusTerminal()
    }

    /// 端末の現在の作業ディレクトリ (分割時に新ペインへ引き継ぐ)。
    func currentDirectory() -> String? {
        terminalHost.currentDirectory()
    }

    // MARK: - Issue 投入

    /// 外部 (IPC / CLI 経由など) からこのペインへ Issue をアサインする。
    /// ヘッダ手入力と同じ経路を通すので、claude 起動〜PR 監視まで一貫して動く。
    func assignIssue(urlString: String) {
        handleIssueSubmission(urlString)
    }

    private func handleIssueSubmission(_ urlString: String) {
        guard let url = URL(string: urlString),
              let parsed = try? GitHubClient.parseIssueUrl(url) else {
            header.showIssueError("Issue URL を解釈できません")
            return
        }

        Task { @MainActor in
            do {
                let issue = try await client.fetchIssue(url: url)
                header.showIssue(title: issue.title, number: issue.number, url: issue.url)
                header.showIssueStatus(state: issue.state)

                // ClaudeSession を起動 (PTY へ claude コマンドを送る)。
                // 本文はペーストで投入し、Enter で実行確定する (bracketed paste 対策)。
                let session = ClaudeSession(
                    sink: { [weak self] text in self?.terminalHost.sendToTerminal(text) },
                    submit: { [weak self] in self?.terminalHost.submitLine() }
                )
                self.session = session
                session.start(
                    issue: issue,
                    promptTemplate: config.initialPrompt,
                    agentCommand: config.agentCommand
                )

                // Issue 自体の Open/Close も継続監視する (作業中に閉じられることがある)。
                startIssueWatching(url: issue.url)

                // Issue を参照する PR が現れるのを待つ。
                header.showPRSearching()
                startPRDiscovery(owner: parsed.owner, repo: parsed.repo, issueNumber: parsed.number)
            } catch {
                header.showIssueError("Issue 取得に失敗: \(error)")
            }
        }
    }

    // MARK: - PR 探索 → 監視

    /// Issue に紐づく PR の集合を継続的に探索し、増減に追従する。
    /// 1 Issue : N PR を前提とし、新規 PR には watcher を起動、紐付けが消えた PR は監視終了する。
    /// (単一 PR を見つけて終了するのではなく、後から増える PR も拾えるよう探索は回し続ける)
    private func startPRDiscovery(owner: String, repo: String, issueNumber: Int) {
        prDiscoveryTask?.cancel()
        prDiscoveryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let urls = try await self.client.linkedPullRequestURLs(
                        owner: owner, repo: repo, issueNumber: issueNumber)
                    await MainActor.run { self.reconcilePRWatchers(urls) }
                } catch {
                    // gh 失敗などはユーザーに見せる (無言ループにしない)。
                    log.error("PR discovery failed: \(String(describing: error))")
                    await MainActor.run { self.header.showPRError(self.shortError(error)) }
                }
                try? await Task.sleep(nanoseconds: self.pollInterval * 1_000_000_000)
            }
        }
    }

    /// GitHub 上の紐付け集合 `urls` に、監視タスクとヘッダ行を一致させる。
    @MainActor
    private func reconcilePRWatchers(_ urls: [URL]) {
        let current = Set(urls)
        // 紐付けが消えた PR は監視終了 + 行削除。
        for url in prWatchTasks.keys where !current.contains(url) {
            prWatchTasks[url]?.cancel()
            prWatchTasks[url] = nil
            header.removePR(url: url)
        }
        guard !urls.isEmpty else {
            header.showPRSearching()
            return
        }
        // 新規 PR は行を即時表示し (URL から番号)、watcher を起動して状態を埋める。
        for url in urls where prWatchTasks[url] == nil {
            header.ensurePR(url: url)
            prWatchTasks[url] = makePRWatchTask(prURL: url)
        }
    }

    /// エラーを 1 行に短縮する (ヘッダ表示用)。
    private func shortError(_ error: Error) -> String {
        let s = String(describing: error)
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }

    /// Issue の Open/Close 状態を定期的に再取得してバッジを更新する。
    /// 初期表示は handleIssueSubmission で済ませているので、ここは次回以降の差分を拾う。
    private func startIssueWatching(url: URL) {
        issueWatchTask?.cancel()
        issueWatchTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.pollInterval * 1_000_000_000)
                if let issue = try? await self.client.fetchIssue(url: url) {
                    await MainActor.run { self.header.showIssueStatus(state: issue.state) }
                }
            }
        }
    }

    /// 1 つの PR を周期監視し、状態をその行へ反映するタスクを作る。
    private func makePRWatchTask(prURL: URL) -> Task<Void, Never> {
        let watcher = PullRequestWatcher(prURL: prURL, client: client)
        return Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let events = try? await watcher.tick() {
                    let ci = await watcher.currentCIStatus()
                    let snapshot = await watcher.snapshot()
                    await MainActor.run {
                        if let pr = snapshot {
                            self.header.updatePR(url: prURL, number: pr.number, state: pr.state, ci: ci)
                        }
                        self.handleEvents(events, prURL: prURL)
                    }
                }
                try? await Task.sleep(nanoseconds: self.pollInterval * 1_000_000_000)
            }
        }
    }

    /// 同種の自動プロンプトを連続送信しないためのクールダウン (秒)。
    /// 例: CI が pending↔failure を往復しても、claude が対処中の間は再送しない。
    private let autoPromptCooldown: TimeInterval = 180
    private var lastAutoPromptAt: [String: Date] = [:]

    /// PR の状態変化イベントを自動プロンプトに変換して claude へ送る。
    private func handleEvents(_ events: [PullRequestWatcher.Event], prURL: URL) {
        for event in events {
            guard let prompt = autoPromptRules.prompt(for: event, prURL: prURL) else { continue }
            // クールダウンは PR ごとに分ける (別 PR の同種イベントを巻き込まない)。
            let key = "\(prURL.absoluteString)#\(Self.eventKey(event))"
            let now = Date()
            if let last = lastAutoPromptAt[key], now.timeIntervalSince(last) < autoPromptCooldown {
                log.info("auto-prompt suppressed (cooldown): \(key)")
                continue
            }
            lastAutoPromptAt[key] = now
            session?.send(prompt: prompt)
        }
    }

    /// イベントの種類キー (クールダウン判定用)。同じ種類は一定時間再送しない。
    private static func eventKey(_ event: PullRequestWatcher.Event) -> String {
        switch event {
        // CI 成功は別キーにして、直前の ci 失敗プロンプトのクールダウンに巻き込まれず
        // 確実に Pass フックを発火させる。失敗の連続再送抑止は "ci" のまま維持。
        case .ciStateChanged(_, let to): return to == .success ? "ci-pass" : "ci"
        case .mergeableChanged: return "mergeable"
        case .reviewAdded: return "review"
        case .stateChanged: return "state"
        }
    }
}
