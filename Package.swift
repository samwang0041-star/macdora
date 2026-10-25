// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AndroidUse",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "AndroidUse", targets: ["AndroidUse"])],
    targets: [
        .executableTarget(name: "AndroidUse"),
        .testTarget(name: "AndroidUseTests", dependencies: ["AndroidUse"], path: "Tests/AndroidUseTests")
    ],
    swiftLanguageModes: [.v5]
)
