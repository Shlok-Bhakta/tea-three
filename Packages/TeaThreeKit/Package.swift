// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TeaThreeKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "TeaThreeKit", targets: ["TeaThreeKit"]),
        .executable(name: "tea-three", targets: ["TeaThreeCLI"]),
    ],
    targets: [
        .target(name: "TeaThreeKit"),
        .executableTarget(name: "TeaThreeCLI", dependencies: ["TeaThreeKit"]),
        .testTarget(
            name: "TeaThreeKitTests",
            dependencies: ["TeaThreeKit"],
            resources: [.copy("Fixtures")]
        ),
        // Talks to a real T3 Code server. Skipped unless T3_CONTRACT_URL is set.
        .testTarget(name: "LiveContractTests", dependencies: ["TeaThreeKit"]),
    ]
)
