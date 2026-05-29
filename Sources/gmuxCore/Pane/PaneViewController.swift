import AppKit
import Ghostty

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
    private let autoPromptRules = AutoPromptRules()
    private var session: ClaudeSession?

    /// 監視ループのキャンセル用タスク。
    private var prDiscoveryTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    /// PR/CI 監視の間隔 (秒)。
    private let pollInterval: UInt64 = 15

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
                header.showIssue(title: issue.title, number: issue.number)

                // ClaudeSession を起動 (PTY へ claude コマンドを送る)。
                let session = ClaudeSession(sink: { [weak self] text in
                    self?.terminalHost.sendToTerminal(text)
                })
                self.session = session
                session.start(issue: issue)

                // Issue を参照する PR が現れるのを待つ。
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
                if let pr = try? await self.client.findPullRequest(
                    forIssueNumber: issueNumber, owner: owner, repo: repo
                ) {
                    await MainActor.run {
                        self.header.showPR(number: pr.number, url: pr.url.absoluteString)
                        self.header.showCIStatus(GitHub.CIStatus.roll(pr.statusCheckRollup ?? []))
                        self.startWatching(prURL: pr.url)
                    }
                    return // 発見したら探索終了、監視へ移行
                }
                try? await Task.sleep(nanoseconds: self.pollInterval * 1_000_000_000)
            }
        }
    }

    private func startWatching(prURL: URL) {
        watchTask?.cancel()
        let watcher = PullRequestWatcher(prURL: prURL, client: client)
        watchTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let events = try? await watcher.tick() {
                    let ci = await watcher.currentCIStatus()
                    await MainActor.run {
                        self.header.showCIStatus(ci)
                        self.handleEvents(events, prURL: prURL)
                    }
                }
                try? await Task.sleep(nanoseconds: self.pollInterval * 1_000_000_000)
            }
        }
    }

    /// PR の状態変化イベントを自動プロンプトに変換して claude へ送る。
    private func handleEvents(_ events: [PullRequestWatcher.Event], prURL: URL) {
        for event in events {
            if let prompt = autoPromptRules.prompt(for: event, prURL: prURL) {
                session?.send(prompt: prompt)
            }
        }
    }
}
