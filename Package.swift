// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HighlightBoba",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HighlightBoba", targets: ["HighlightBoba"])
    ],
    targets: [
        .target(name: "HighlightBoba", resources: [.copy("Grammars")]),
        .testTarget(name: "HighlightBobaTests", dependencies: ["HighlightBoba"], exclude: ["Fixtures"])
    ]
)
