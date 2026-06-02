import AppKit
import Ghostty
import os

private let log = Logger(subsystem: "com.gmux.core", category: "pane")

/// 1 ペイン = ヘッダ(Issue / PR) + ターミナル領域 (libghostty Surface)。
///
/// CONCEPT のコアフローを束ねるコーディネータ:
///   Issue URL 入力 → GitHubClient.fetchIssue → ヘッダ描画 → ClaudeSession 起動
///   → 定期的に Issue を参照する PR を探索 → 発見後 PullRequestWatcher で CI を監視
///   → 状態変化を AutoPromptRules でプロンプト化し ClaudeSession へ送信。
final class PaneViewController: NSViewController {

    private let header = PaneHeaderView()
    private let terminalHost = TerminalHostView()

    private let client = GitHubClient()
    /// ユーザー設定 (~/.config/gmux/config.toml)。
    private let config = GmuxConfig.current
    private lazy var autoPromptRules = AutoPromptRules(config: config.autoPrompts)
    private var session: ClaudeSession?

    /// 監視ループのキャンセル用タスク。
    private var prDiscoveryTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    /// PR/CI 監視の間隔 (秒)。設定から取得。
    private lazy var pollInterval: UInt64 = UInt64(max(1, config.pollIntervalSeconds))

    override func loadView() {
        let root = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(terminalHost)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 64),

            terminalHost.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminalHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        header.onSubmitIssueURL = { [weak self] urlString in
            self?.handleIssueSubmission(urlString)
        }
        view = root
    }

    deinit {
        prDiscoveryTask?.cancel()
        watchTask?.cancel()
    }

    /// 端末をキーボードフォーカスにする (分割直後・フォーカス移動時に呼ぶ)。
    func focusTerminal() {
        terminalHost.focusTerminal()
    }

    // MARK: - Issue 投入

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

                // ClaudeSession を起動 (PTY へ claude コマンドを送る)。
                let session = ClaudeSession(sink: { [weak self] text in
                    self?.terminalHost.sendToTerminal(text)
                })
                self.session = session
                session.start(
                    issue: issue,
                    promptTemplate: config.initialPrompt,
                    agentCommand: config.agentCommand
                )

                // Issue を参照する PR が現れるのを待つ。
                header.showPRSearching()
                startPRDiscovery(owner: parsed.owner, repo: parsed.repo, issueNumber: parsed.number)
            } catch {
                header.showIssueError("Issue 取得に失敗: \(error)")
            }
        }
    }

    // MARK: - PR 探索 → 監視

    private func startPRDiscovery(owner: String, repo: String, issueNumber: Int) {
        prDiscoveryTask?.cancel()
        prDiscoveryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    if let pr = try await self.client.findPullRequest(
                        forIssueNumber: issueNumber, owner: owner, repo: repo
                    ) {
                        await MainActor.run {
                            self.header.showPR(number: pr.number, url: pr.url)
                            self.header.showStatus(prState: pr.state, ci: GitHub.CIStatus.roll(pr.statusCheckRollup ?? []))
                            self.startWatching(prURL: pr.url)
                        }
                        return // 発見したら探索終了、監視へ移行
                    }
                    // 見つからない (= まだ PR 未作成)。探索中表示のまま次のポーリングへ。
                } catch {
                    // gh 失敗などはユーザーに見せる (無言ループにしない)。
                    log.error("PR discovery failed: \(String(describing: error))")
                    await MainActor.run { self.header.showPRError(self.shortError(error)) }
                }
                try? await Task.sleep(nanoseconds: self.pollInterval * 1_000_000_000)
            }
        }
    }

    /// エラーを 1 行に短縮する (ヘッダ表示用)。
    private func shortError(_ error: Error) -> String {
        let s = String(describing: error)
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }

    private func startWatching(prURL: URL) {
        watchTask?.cancel()
        let watcher = PullRequestWatcher(prURL: prURL, client: client)
        watchTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let events = try? await watcher.tick() {
                    let ci = await watcher.currentCIStatus()
                    let snapshot = await watcher.snapshot()
                    await MainActor.run {
                        if let pr = snapshot {
                            self.header.showPR(number: pr.number, url: pr.url)
                            self.header.showStatus(prState: pr.state, ci: ci)
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
            let key = Self.eventKey(event)
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
        case .ciStateChanged: return "ci"
        case .mergeableChanged: return "mergeable"
        case .reviewAdded: return "review"
        case .stateChanged: return "state"
        }
    }
}
