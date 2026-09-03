// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "xml-macker",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "XMLMacker",
            path: "Sources/xml-macker"
        ),
        .testTarget(
            name: "XMLMackerTests",
            dependencies: ["XMLMacker"],
            path: "Tests/xml-macker-tests"
        )
    ]
)
