import AppKit
import CGhostty
import os

extension Ghostty {
    static let logger = Logger(subsystem: "com.ghmux.Ghostty", category: "ghostty")

    /// プロセス全体で 1 つだけ存在する libghostty アプリ。
    /// 全ペインの `SurfaceView` がこの `app` を共有して surface を生成する。
    ///
    /// `shared` は遅延生成。最初に `Surface` が window へ接続したときに初めて初期化されるため、
    /// window を持たないユニットテストでは libghostty を起動しない。
    public final class App {
        public static let shared = App()

        /// libghostty アプリハンドル。初期化失敗時は nil。
        private(set) var app: ghostty_app_t?
        private var config: ghostty_config_t?

        /// 初期化に成功したか。
        public var isReady: Bool { app != nil }

        private init() {
            // libghostty のグローバル初期化 (プロセス一度きり)。
            ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)

            // 同梱リソース (themes / shell-integration / terminfo) を pane の PTY に伝える。
            // ここで setenv したものは Ghostty.swift の per-surface env_vars が継承するため
            // pane 内のシェルまで伝播する。
            Self.configureResourceEnvironment()

            // 設定をロード (~/.config/ghostty/config を継承)。
            guard let cfg = ghostty_config_new() else {
                Ghostty.logger.critical("ghostty_config_new failed")
                return
            }
            ghostty_config_load_default_files(cfg)
            ghostty_config_finalize(cfg)
            self.config = cfg

            // ランタイム設定。6 コールバックは全て埋める必要があるが、
            // clipboard 系と close は当面 no-op で良い。
            var runtime = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: false,
                wakeup_cb: { userdata in App.wakeup(userdata) },
                action_cb: { _, _, _ in false },
                read_clipboard_cb: { userdata, location, state in
                    App.readClipboard(userdata, location: location, state: state)
                },
                confirm_read_clipboard_cb: { _, _, _, _ in },
                write_clipboard_cb: { userdata, location, content, len, confirm in
                    App.writeClipboard(userdata, location: location, content: content, len: len, confirm: confirm)
                },
                close_surface_cb: { _, _ in }
            )

            guard let app = ghostty_app_new(&runtime, cfg) else {
                Ghostty.logger.critical("ghostty_app_new failed")
                return
            }
            self.app = app
            ghostty_app_set_focus(app, NSApp.isActive)
        }

        deinit {
            if let app { ghostty_app_free(app) }
            if let config { ghostty_config_free(config) }
        }

        // MARK: - 非アクティブペインのディム設定

        // ghostty 本家 (macos/Sources/Ghostty/Ghostty.Config.swift) と同じ方式で、
        // ロード済みの ghostty config から「非アクティブ split を暗くする」パラメータを読む。
        // ghmux 独自 config を増やさず、ユーザーの ~/.config/ghostty/config を尊重する。

        /// 非アクティブペインに重ねるディム矩形の不透明度。
        /// config の `unfocused-split-opacity` (1=無効) の逆数。取得不可時は 0.3 相当。
        public var unfocusedSplitOverlayAlpha: Double {
            guard let config else { return 0.3 }
            var opacity: Double = 0.7
            let key = "unfocused-split-opacity"
            _ = ghostty_config_get(config, &opacity, key, UInt(key.lengthOfBytes(using: .utf8)))
            return 1 - opacity
        }

        /// ディム矩形の塗り色。config の `unfocused-split-fill`、無ければ `background` にフォールバック。
        public var unfocusedSplitFill: NSColor {
            guard let config else { return .black }
            var color = ghostty_config_color_s()
            let key = "unfocused-split-fill"
            if !ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) {
                let bgKey = "background"
                _ = ghostty_config_get(config, &color, bgKey, UInt(bgKey.lengthOfBytes(using: .utf8)))
            }
            return NSColor(
                red: CGFloat(color.r) / 255,
                green: CGFloat(color.g) / 255,
                blue: CGFloat(color.b) / 255,
                alpha: 1
            )
        }

        /// libghostty にイベントループの 1 tick を処理させる。
        func tick() {
            guard let app else { return }
            ghostty_app_tick(app)
        }

        /// wakeup は任意スレッドから呼ばれるため、main で tick をスケジュールする。
        private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            guard let userdata else { return }
            let app = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async { app.tick() }
        }

        // MARK: - クリップボード

        // clipboard コールバックの userdata は surface の userdata (= SurfaceView)。
        private static func surfaceView(from userdata: UnsafeMutableRawPointer?) -> SurfaceView? {
            guard let userdata else { return nil }
            return Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        }

        /// 端末がペースト等でクリップボード読み取りを要求したとき。
        /// NSPasteboard の文字列を ghostty に返す。
        private static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            state: UnsafeMutableRawPointer?
        ) -> Bool {
            guard location == GHOSTTY_CLIPBOARD_STANDARD else { return false }
            guard let view = surfaceView(from: userdata), let surface = view.surface else { return false }
            guard let str = NSPasteboard.general.string(forType: .string) else { return false }
            // confirmed=true: 確認ダイアログ UI は未実装のため、そのままペーストを許可する。
            str.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, true)
            }
            return true
        }

        /// 端末がコピー等でクリップボード書き込みを要求したとき。
        private static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            content: UnsafePointer<ghostty_clipboard_content_s>?,
            len: Int,
            confirm: Bool
        ) {
            guard location == GHOSTTY_CLIPBOARD_STANDARD else { return }
            guard let content, len > 0, let dataPtr = content[0].data else { return }
            let str = String(cString: dataPtr)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(str, forType: .string)
        }

        /// 同梱リソースに基づき GHOSTTY_RESOURCES_DIR / TERMINFO / COLORTERM を設定する。
        /// TERM は libghostty が xterm-ghostty を立てるため触らない (未設定時のみ補完)。
        private static func configureResourceEnvironment() {
            guard let root = resolvedResourcesRoot() else { return }
            let fm = FileManager.default

            // themes / shell-integration の探索先。
            setenv("GHOSTTY_RESOURCES_DIR", root + "/ghostty", 1)

            // ncurses が xterm-ghostty を解決するための terminfo DB。
            // これが無いと pane 内の vim/less/tmux 等が "terminal is not fully functional" になる。
            let terminfo = root + "/terminfo"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: terminfo, isDirectory: &isDir), isDir.boolValue,
                getenv("TERMINFO") == nil {
                setenv("TERMINFO", terminfo, 1)
            }

            if getenv("COLORTERM") == nil {
                setenv("COLORTERM", "truecolor", 1)
            }
            if getenv("TERM") == nil {
                setenv("TERM", "xterm-ghostty", 1)
            }

            // .app バンドルでは実体が Contents/MacOS に埋もれ PATH に乗らないため、
            // pane 内の `ghmux pane new` (子ペイン生成の IPC クライアント) が解決できない。
            // 実行バイナリのディレクトリを PATH 先頭へ加える。
            if let dir = Self.executableDirectory() {
                prependToPath(dir)
            }
        }

        /// 実行バイナリのあるディレクトリ (.app では Contents/MacOS)。
        private static func executableDirectory() -> String? {
            guard let exe = Bundle.main.executablePath else { return nil }
            return (exe as NSString).deletingLastPathComponent
        }

        /// `dir` が PATH に未登録なら先頭へ prepend する。
        private static func prependToPath(_ dir: String) {
            let current = getenv("PATH").flatMap { String(cString: $0) } ?? ""
            let entries = current.split(separator: ":").map(String.init)
            guard !entries.contains(dir) else { return }
            let updated = current.isEmpty ? dir : "\(dir):\(current)"
            setenv("PATH", updated, 1)
        }

        /// 同梱リソース root (配下に `ghostty/` と `terminfo/` を持つ) を解決する。
        /// テスト容易化のため探索ロジックを純関数に分離する。
        static func resolvedResourcesRoot(
            resourcePath: String = Bundle.main.resourcePath ?? Bundle.main.bundlePath,
            bundlePath: String = Bundle.main.bundlePath,
            currentDirectory: String = FileManager.default.currentDirectoryPath,
            systemGhosttyResources: String = "/Applications/Ghostty.app/Contents/Resources/ghostty",
            fileManager: FileManager = .default
        ) -> String? {
            func isDirectory(_ path: String) -> Bool {
                var isDir: ObjCBool = false
                return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }

            // 1. .app の Contents/Resources / 2. 配布バイナリ隣接 / 3. 開発時のソースツリー。
            let candidates = [
                resourcePath + "/ghostty-resources",
                bundlePath + "/../ghostty-resources",
                currentDirectory + "/Vendored/ghostty-resources",
            ]
            for path in candidates where isDirectory(path) {
                return path
            }

            // 4. システムにインストール済みの Ghostty.app をフォールバックに使う。
            //    systemGhosttyResources は <root>/ghostty を指すため、その親を root とする。
            if isDirectory(systemGhosttyResources) {
                return (systemGhosttyResources as NSString).deletingLastPathComponent
            }
            return nil
        }
    }
}
