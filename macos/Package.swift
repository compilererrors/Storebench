// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Storebench",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StorebenchCore", targets: ["StorebenchCore"]),
        .executable(name: "Storebench", targets: ["StorebenchApp"]),
        .executable(name: "StorebenchPolicyFixtures", targets: ["StorebenchPolicyFixtures"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.19.0"),
    ],
    targets: [
        .target(name: "StorebenchCore", dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")], resources: [.copy("Resources/help-topics.json"), .copy("Resources/recovery-guidance.json"), .copy("Resources/reporting-sources.json"), .copy("Resources/design.json")]),
        .executableTarget(name: "StorebenchApp", dependencies: ["StorebenchCore"]),
        .executableTarget(name: "StorebenchPolicyFixtures", dependencies: ["StorebenchCore"]),
        .testTarget(name: "StorebenchAppTests", dependencies: ["StorebenchApp", "StorebenchCore"]),
        .testTarget(name: "StorebenchCoreTests", dependencies: ["StorebenchCore"], resources: [.copy("Fixtures/synthetic-journal.json"), .copy("Fixtures/synthetic-progress.json")]),
    ]
)
