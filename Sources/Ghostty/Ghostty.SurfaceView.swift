import AppKit
import CGhostty

extension Ghostty {
    /// libghostty surface をホストする AppKit ビュー。
    /// window へ接続したタイミングで `ghostty_surface_new` を呼び、Metal 描画と PTY を起動する。
    ///
    /// reference: vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift
    /// gmux では MVP に必要な範囲 (描画 / キー入力 / マウス / リサイズ / フォーカス) に絞る。
    public final class SurfaceView: NSView, NSTextInputClient {
        private let configuration: Surface.Configuration
        private(set) var surface: ghostty_surface_t?

        /// keyDown 中に interpretKeyEvents が IME 経由で確定したテキストを溜めるバッファ。
        private var keyTextAccumulator: [String]?

        /// 現在の論理サイズ (point)。backing 変換に使う。
        private var contentSize: CGSize = .zero

        init(configuration: Surface.Configuration) {
            self.configuration = configuration
            super.init(frame: .zero)
            // libghostty が内部で Metal レイヤを管理するため layer-backed にする。
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Use init(configuration:)") }

        deinit {
            if let surface { ghostty_surface_free(surface) }
        }

        // MARK: - ライフサイクル

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, surface == nil {
                createSurface()
            }
        }

        private func createSurface() {
            guard let app = App.shared.app else {
                Ghostty.logger.error("Ghostty app not ready; cannot create surface")
                return
            }
            contentSize = bounds.size

            let created = configuration.withCValue(view: self) { cfg -> ghostty_surface_t? in
                var cfg = cfg
                return ghostty_surface_new(app, &cfg)
            }
            guard let created else {
                Ghostty.logger.error("ghostty_surface_new failed")
                return
            }
            self.surface = created

            // 初期のスケール / サイズ / フォーカスを通知。
            updateContentScale()
            updateSurfaceSize(bounds.size)
            ghostty_surface_set_focus(created, window?.isKeyWindow ?? false)
        }

        // MARK: - サイズ / スケール

        public override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            contentSize = newSize
            updateSurfaceSize(newSize)
        }

        public override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            if let window {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer?.contentsScale = window.backingScaleFactor
                CATransaction.commit()
            }
            updateContentScale()
            updateSurfaceSize(contentSize)
        }

        private func updateContentScale() {
            guard let surface else { return }
            let fbFrame = convertToBacking(frame)
            let xScale = frame.size.width > 0 ? fbFrame.size.width / frame.size.width : 1
            let yScale = frame.size.height > 0 ? fbFrame.size.height / frame.size.height : 1
            ghostty_surface_set_content_scale(surface, xScale, yScale)
        }

        private func updateSurfaceSize(_ size: CGSize) {
            guard let surface else { return }
            let scaled = convertToBacking(CGRect(origin: .zero, size: size)).size
            ghostty_surface_set_size(surface, UInt32(max(scaled.width, 1)), UInt32(max(scaled.height, 1)))
        }

        // MARK: - フォーカス

        public override var acceptsFirstResponder: Bool { true }

        public override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result, let surface { ghostty_surface_set_focus(surface, true) }
            return result
        }

        public override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result, let surface { ghostty_surface_set_focus(surface, false) }
            return result
        }

        // MARK: - 公開 API

        /// PTY にテキストを直接送る (ClaudeSession のプロンプト投入用)。
        func sendText(_ text: String) {
            guard let surface else { return }
            text.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
            }
        }

        // MARK: - キーボード入力

        public override func keyDown(with event: NSEvent) {
            guard surface != nil else {
                interpretKeyEvents([event])
                return
            }
            let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

            // interpretKeyEvents 中の insertText を捕捉するためにアキュムレータを立てる。
            keyTextAccumulator = []
            defer { keyTextAccumulator = nil }

            let markedBefore = markedTextLength > 0
            interpretKeyEvents([event])

            // preedit 状態を同期。
            syncPreedit()
            let composing = markedTextLength > 0 || markedBefore

            if let list = keyTextAccumulator, !list.isEmpty {
                // IME が確定したテキスト。
                for text in list {
                    _ = keyAction(action, event: event, text: text)
                }
            } else {
                _ = keyAction(action, event: event, text: event.ghosttyCharacters, composing: composing)
            }
        }

        public override func keyUp(with event: NSEvent) {
            _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
        }

        public override func flagsChanged(with event: NSEvent) {
            // modifier の押下/解放。press/release は keycode の状態で決めるのは複雑なので
            // ghostty に press として渡し、mods で状態を伝える (reference も press 扱い)。
            _ = keyAction(GHOSTTY_ACTION_PRESS, event: event)
        }

        @discardableResult
        private func keyAction(
            _ action: ghostty_input_action_e,
            event: NSEvent,
            text: String? = nil,
            composing: Bool = false
        ) -> Bool {
            guard let surface else { return false }
            var key_ev = event.ghosttyKeyEvent(action)
            key_ev.composing = composing

            // 制御文字は ghostty 側でエンコードするため text には載せない。
            if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
                return text.withCString { ptr in
                    key_ev.text = ptr
                    return ghostty_surface_key(surface, key_ev)
                }
            }
            return ghostty_surface_key(surface, key_ev)
        }

        // MARK: - マウス

        public override func mouseDown(with event: NSEvent) {
            guard let surface else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        }

        public override func mouseUp(with event: NSEvent) {
            guard let surface else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        }

        public override func rightMouseDown(with event: NSEvent) {
            guard let surface else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods)
        }

        public override func rightMouseUp(with event: NSEvent) {
            guard let surface else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods)
        }

        public override func mouseMoved(with event: NSEvent) { reportMousePos(event) }
        public override func mouseDragged(with event: NSEvent) { reportMousePos(event) }

        private func reportMousePos(_ event: NSEvent) {
            guard let surface else { return }
            let pos = convert(event.locationInWindow, from: nil)
            // libghostty は左上原点。AppKit は左下原点なので Y を反転。
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, mods)
        }

        public override func scrollWheel(with event: NSEvent) {
            guard let surface else { return }
            var mods: Int32 = 0
            if event.hasPreciseScrollingDeltas {
                mods = 1
                // 高精度デバイス: pixel 単位。
            }
            if event.momentumPhase != [] {
                mods |= 2
            }
            ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, mods)
        }

        // MARK: - NSTextInputClient

        private var markedTextStorage = NSMutableAttributedString()
        private var markedTextLength: Int { markedTextStorage.length }

        public func insertText(_ string: Any, replacementRange: NSRange) {
            let chars: String
            switch string {
            case let v as NSAttributedString: chars = v.string
            case let v as String: chars = v
            default: return
            }
            unmarkText()
            // keyDown 経由なら確定テキストをアキュムレータに溜める。
            if keyTextAccumulator != nil {
                keyTextAccumulator?.append(chars)
                return
            }
            sendText(chars)
        }

        public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            switch string {
            case let v as NSAttributedString: markedTextStorage = NSMutableAttributedString(attributedString: v)
            case let v as String: markedTextStorage = NSMutableAttributedString(string: v)
            default: markedTextStorage = NSMutableAttributedString()
            }
        }

        public func unmarkText() {
            markedTextStorage = NSMutableAttributedString()
        }

        /// markedText の内容を libghostty の preedit に反映する。
        private func syncPreedit() {
            guard let surface else { return }
            let str = markedTextStorage.string
            if str.isEmpty {
                ghostty_surface_preedit(surface, nil, 0)
            } else {
                str.withCString { ptr in
                    ghostty_surface_preedit(surface, ptr, UInt(strlen(ptr)))
                }
            }
        }

        public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
        public func markedRange() -> NSRange {
            markedTextLength > 0 ? NSRange(location: 0, length: markedTextLength) : NSRange(location: NSNotFound, length: 0)
        }
        public func hasMarkedText() -> Bool { markedTextLength > 0 }
        public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
        public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
        public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
        public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    }
}
