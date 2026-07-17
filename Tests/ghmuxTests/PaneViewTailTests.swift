import Foundation
import Testing
@testable import ghmuxCore

/// `pane view --lines N` の末尾 N 行抽出ロジックを検証する。
@Suite("pane view tail")
struct PaneViewTailTests {

    @Test func nilLinesReturnsWholeText() {
        let text = "a\nb\nc\n"
        #expect(AppDelegate.tail(text, lines: nil) == text)
    }

    @Test func tailTruncatesToLastNLines() {
        // 末尾改行あり: 行数に数えず保持する。
        #expect(AppDelegate.tail("a\nb\nc\nd\n", lines: 2) == "c\nd\n")
    }

    @Test func tailWithoutTrailingNewline() {
        #expect(AppDelegate.tail("a\nb\nc\nd", lines: 2) == "c\nd")
    }

    @Test func linesGreaterThanTotalReturnsAll() {
        let text = "a\nb\n"
        #expect(AppDelegate.tail(text, lines: 1000) == text)
    }

    @Test func linesEqualToTotalReturnsAll() {
        let text = "a\nb\nc"
        #expect(AppDelegate.tail(text, lines: 3) == text)
    }
}
