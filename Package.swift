// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Stoneaxe",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Stoneaxe", targets: ["Stoneaxe"])],
    targets: [
        .target(name: "StoneaxeCore"),
        .executableTarget(name: "Stoneaxe", dependencies: ["StoneaxeCore"],
                          resources: [.copy("Resources/Mining.metal")]),
        .testTarget(name: "StoneaxeCoreTests", dependencies: ["StoneaxeCore"]),
        .testTarget(name: "StoneaxeAppTests", dependencies: ["Stoneaxe", "StoneaxeCore"])
    ]
)
