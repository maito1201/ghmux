import AppKit
import Testing
@testable import Ghostty

// window 非依存テスト。Surface は window へ接続するまで実 libghostty surface を生成しないため、
// ヘッドレスでも Metal/PTY を起動せず安全に検証できる (Phase 1-D 設計)。
@Suite("Ghostty.Surface")
struct GhosttySurfaceTests {

    @Test func makeViewReturnsSurfaceViewWithoutWindow() {
        let surface = Ghostty.Surface()
        let view = surface.makeView()
        #expect(view is Ghostty.SurfaceView)
        // window 未接続なので実 surface は生成されない。
        #expect((view as? Ghostty.SurfaceView)?.surface == nil)
    }

    @Test func makeViewIsStable() {
        let surface = Ghostty.Surface()
        let v1 = surface.makeView()
        let v2 = surface.makeView()
        #expect(v1 === v2) // 2 回呼んでも同じ View を返す
    }

    @Test func sendWithoutWindowIsSafe() {
        let surface = Ghostty.Surface()
        _ = surface.makeView()
        surface.send("hello") // surface 未生成でもクラッシュしない
    }

    @Test func configurationDefaults() {
        let config = Ghostty.Surface.Configuration()
        #expect(config.initialCommand == nil)
        #expect(config.workingDirectory == nil)
        #expect(config.environment.isEmpty)
    }

    @Test func configurationCustom() {
        let config = Ghostty.Surface.Configuration(
            initialCommand: "claude",
            workingDirectory: "/tmp",
            environment: ["FOO": "bar"]
        )
        #expect(config.initialCommand == "claude")
        #expect(config.workingDirectory == "/tmp")
        #expect(config.environment["FOO"] == "bar")
    }
}
