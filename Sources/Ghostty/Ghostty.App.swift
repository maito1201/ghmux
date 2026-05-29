import AppKit
import CGhostty
import os

extension Ghostty {
    static let logger = Logger(subsystem: "com.gmux.Ghostty", category: "ghostty")

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

            // GHOSTTY_RESOURCES_DIR: terminfo / シェル統合の探索先。
            // build-libghostty.sh が Vendored/ghostty-resources にコピーしている場合に指す。
            if let resources = Self.resourcesDirectory {
                setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
            }

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

        /// Vendored/ghostty-resources が存在すればそのパスを返す。
        private static var resourcesDirectory: String? {
            // 実行バイナリからの相対 + よく使う固定パスを探索する。
            let candidates: [String] = [
                Bundle.main.bundlePath + "/../ghostty-resources",
                FileManager.default.currentDirectoryPath + "/Vendored/ghostty-resources",
            ]
            for path in candidates {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    return path
                }
            }
            return nil
        }
    }
}
