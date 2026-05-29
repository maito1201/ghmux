import AppKit
import CGhostty

// NSEvent / modifier を libghostty の入力構造体に変換するための最小ユーティリティ。
// reference: vendor/ghostty/macos/Sources/Ghostty/{Ghostty.Input.swift, NSEvent+Extension.swift}
// gmux では IME のフル機能ではなく、ASCII + 一般的な合成入力が動く範囲に簡略化している。

extension Ghostty {
    /// AppKit の modifier flag を libghostty の mods bitmask に変換する。
    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }
}

extension NSEvent {
    /// keyDown/keyUp イベントから ghostty_input_key_s を構築する。
    /// text / composing は呼び出し側で設定する (C 文字列の寿命管理のため)。
    func ghosttyKeyEvent(_ action: ghostty_input_action_e) -> ghostty_input_key_s {
        var key_ev = ghostty_input_key_s()
        key_ev.action = action
        key_ev.keycode = UInt32(keyCode)
        key_ev.text = nil
        key_ev.composing = false

        // control / command は文字変換に寄与しないものとして consumed から除外する
        // (reference のヒューリスティクスを踏襲)。
        key_ev.mods = Ghostty.ghosttyMods(modifierFlags)
        key_ev.consumed_mods = Ghostty.ghosttyMods(
            modifierFlags.subtracting([.control, .command]))

        key_ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                key_ev.unshifted_codepoint = codepoint.value
            }
        }
        return key_ev
    }

    /// ghostty に送るべき文字列。制御文字 (ghostty が自前でエンコードする) と
    /// PUA のファンクションキーは除外する。
    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }
}
