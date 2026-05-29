// swift-tools-version:5.10
import PackageDescription

// Phase 1-D: Ghostty.xcframework を binaryTarget で取り込む構成。
//   - GhosttyKit (binaryTarget)  … libghostty 本体。リンク時にシンボルを供給。
//   - CGhostty   (C target)      … ghostty.h を Swift へ公開する明示モジュール。
//     SwiftPM の explicit module build は xcframework 内 modulemap を暗黙発見しないため、
//     自前の C ターゲットでモジュールを登録する。
//   - Ghostty    (Swift target)  … Ghostty.Surface 等の Swift ラッパー。import CGhostty。

let package = Package(
    name: "gmux",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "gmux", targets: ["gmux"]),
        .library(name: "gmuxCore", targets: ["gmuxCore"]),
        .library(name: "Ghostty", targets: ["Ghostty"]),
    ],
    targets: [
        .executableTarget(
            name: "gmux",
            dependencies: ["gmuxCore"],
            path: "Sources/gmux"
        ),
        .target(
            name: "gmuxCore",
            dependencies: ["Ghostty"],
            path: "Sources/gmuxCore"
        ),
        .target(
            name: "Ghostty",
            dependencies: ["CGhostty", "GhosttyKit"],
            path: "Sources/Ghostty"
        ),
        .target(
            name: "CGhostty",
            dependencies: ["GhosttyKit"],
            path: "Sources/CGhostty",
            publicHeadersPath: "include",
            linkerSettings: [
                // libghostty が依存するシステムライブラリ / フレームワーク。
                // glslang (C++) などのため libc++ が必須。
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedFramework("Cocoa"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Carbon"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .binaryTarget(
            name: "GhosttyKit",
            path: "Vendored/GhosttyKit.xcframework"
        ),
        .testTarget(
            name: "gmuxTests",
            dependencies: ["gmuxCore", "Ghostty"],
            path: "Tests/gmuxTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
