// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CheatSheet",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CheatSheetCore", targets: ["CheatSheetCore"]),
        .executable(name: "CheatSheet", targets: ["CheatSheetApp"]),
    ],
    targets: [
        .target(name: "CheatSheetCore"),
        .executableTarget(name: "CheatSheetApp", dependencies: ["CheatSheetCore"]),
        .testTarget(name: "CheatSheetCoreTests", dependencies: ["CheatSheetCore"]),
    ]
)
