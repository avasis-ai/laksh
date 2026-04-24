// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Laksh",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Laksh", targets: ["Laksh"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "Laksh",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/Laksh",
            exclude: ["Terminal/TerminalRenderer.metal"],
            resources: [.process("Resources")]
        )
    ]
)
