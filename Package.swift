// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "luoke-ime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LuokeShell", targets: ["LuokeShell"]),
        .executable(name: "luoke-ime", targets: ["luoke-ime"]),
        .executable(name: "LuokeIME", targets: ["LuokeIME"]),
    ],
    targets: [
        // 平台无关的一层：状态机、协议、引擎宿主（ADR 0007）。只依赖 Foundation。
        .target(name: "LuokeShell", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "luoke-ime", dependencies: ["LuokeShell"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // macOS 输入法外壳：很薄的一层，把系统事件喂给状态机、把结果画出来（docs/设计.md#macos-外壳实现要点）。
        .executableTarget(name: "LuokeIME", dependencies: ["LuokeShell"], swiftSettings: [.swiftLanguageMode(.v5)],
                          linkerSettings: [.linkedFramework("InputMethodKit"), .linkedFramework("Carbon")]),
        .testTarget(name: "LuokeShellTests", dependencies: ["LuokeShell"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
