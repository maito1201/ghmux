import AppKit
import CGhostty

/// `Ghostty` は libghostty を Swift から扱うための薄いラッパ。
public enum Ghostty {

    /// 1 ターミナルセッションを表す。`SurfaceView` を保持し、AppKit へ埋め込めるようにする。
    public final class Surface {
        public struct Configuration: Sendable, Equatable {
            /// ペイン起動時に exec する初期コマンド。`nil` の場合はログインシェル。
            public var initialCommand: String?
            /// 作業ディレクトリ。`nil` の場合はホーム。
            public var workingDirectory: String?
            /// 環境変数の追加分。
            public var environment: [String: String]

            public init(
                initialCommand: String? = nil,
                workingDirectory: String? = nil,
                environment: [String: String] = [:]
            ) {
                self.initialCommand = initialCommand
                self.workingDirectory = workingDirectory
                self.environment = environment
            }

            /// C 互換の `ghostty_surface_config_s` を構築し、クロージャに渡す。
            /// 文字列ポインタはクロージャの実行中のみ有効。
            func withCValue<T>(view: SurfaceView, _ body: (ghostty_surface_config_s) -> T) -> T {
                var config = ghostty_surface_config_new()
                config.userdata = Unmanaged.passUnretained(view).toOpaque()
                config.platform_tag = GHOSTTY_PLATFORM_MACOS
                config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
                    nsview: Unmanaged.passUnretained(view).toOpaque()
                ))
                config.scale_factor = Double(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
                config.font_size = 0  // 0 = config のデフォルトを継承
                config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

                return optionalWithCString(workingDirectory) { cWorkingDir in
                    config.working_directory = cWorkingDir
                    return optionalWithCString(initialCommand) { cCommand in
                        config.command = cCommand
                        let keys = Array(environment.keys)
                        let values = keys.map { environment[$0]! }
                        return keys.withCStrings { keyPtrs in
                            return values.withCStrings { valuePtrs in
                                var envVars = [ghostty_env_var_s]()
                                envVars.reserveCapacity(keys.count)
                                for i in 0..<keys.count {
                                    envVars.append(ghostty_env_var_s(key: keyPtrs[i], value: valuePtrs[i]))
                                }
                                return envVars.withUnsafeMutableBufferPointer { buf in
                                    config.env_vars = buf.baseAddress
                                    config.env_var_count = keys.count
                                    return body(config)
                                }
                            }
                        }
                    }
                }
            }
        }

        public let configuration: Configuration
        private var surfaceView: SurfaceView?

        public init(configuration: Configuration = Configuration()) {
            self.configuration = configuration
        }

        /// AppKit に埋め込むためのビューを返す (生成は初回のみ)。
        public func makeView() -> NSView {
            if let surfaceView { return surfaceView }
            let view = SurfaceView(configuration: configuration)
            surfaceView = view
            return view
        }

        /// PTY にテキストを送る (改行は呼び出し側で付与)。
        public func send(_ text: String) {
            surfaceView?.sendText(text)
        }
    }
}

// MARK: - C 文字列ヘルパー

/// Optional<String> を C 文字列ポインタ (nil 可) としてクロージャに渡す。
func optionalWithCString<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    if let string {
        return string.withCString { body($0) }
    }
    return body(nil)
}

extension Array where Element == String {
    /// 文字列配列を C 文字列ポインタ配列としてクロージャに渡す。
    func withCStrings<T>(_ body: ([UnsafePointer<CChar>?]) -> T) -> T {
        func helper(_ index: Int, _ acc: [UnsafePointer<CChar>?]) -> T {
            if index == count { return body(acc) }
            return self[index].withCString { ptr in
                helper(index + 1, acc + [ptr])
            }
        }
        return helper(0, [])
    }
}
