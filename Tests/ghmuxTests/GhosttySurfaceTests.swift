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

@Suite("Ghostty.App resource resolution")
struct GhosttyAppResourceTests {
    private let fm = FileManager.default

    /// 一意な作業ディレクトリを作り、相対パス群を mkdir -p する。
    private func makeBase(_ relativeDirs: [String]) throws -> URL {
        let base = fm.temporaryDirectory.appendingPathComponent("ghmux-res-\(UUID().uuidString)")
        for rel in relativeDirs {
            try fm.createDirectory(at: base.appendingPathComponent(rel), withIntermediateDirectories: true)
        }
        return base
    }

    @Test func prefersBundleAdjacentRoot() throws {
        // bin/ (実在) と隣の ghostty-resources/ を用意。bundlePath を base/bin に見立てる。
        let base = try makeBase(["bin", "ghostty-resources/ghostty", "ghostty-resources/terminfo"])
        defer { try? fm.removeItem(at: base) }

        let resolved = Ghostty.App.resolvedResourcesRoot(
            bundlePath: base.path + "/bin",
            currentDirectory: "/nonexistent",
            systemGhosttyResources: "/nonexistent/ghostty"
        )
        #expect(resolved == base.path + "/bin/../ghostty-resources")
    }

    @Test func fallsBackToCurrentDirectory() throws {
        let base = try makeBase(["Vendored/ghostty-resources/ghostty"])
        defer { try? fm.removeItem(at: base) }

        let resolved = Ghostty.App.resolvedResourcesRoot(
            bundlePath: "/nonexistent/bin",
            currentDirectory: base.path,
            systemGhosttyResources: "/nonexistent/ghostty"
        )
        #expect(resolved == base.path + "/Vendored/ghostty-resources")
    }

    @Test func fallsBackToSystemGhosttyParent() throws {
        // systemGhosttyResources は <root>/ghostty を指すため、その親が root として返る。
        let base = try makeBase(["ghostty"])
        defer { try? fm.removeItem(at: base) }

        let resolved = Ghostty.App.resolvedResourcesRoot(
            bundlePath: "/nonexistent/bin",
            currentDirectory: "/nonexistent",
            systemGhosttyResources: base.path + "/ghostty"
        )
        #expect(resolved == base.path)
    }

    @Test func returnsNilWhenNothingExists() {
        let resolved = Ghostty.App.resolvedResourcesRoot(
            bundlePath: "/nonexistent/bin",
            currentDirectory: "/nonexistent",
            systemGhosttyResources: "/nonexistent/ghostty"
        )
        #expect(resolved == nil)
    }
}
