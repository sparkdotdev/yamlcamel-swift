// swift-tools-version: 6.0
import PackageDescription

// The floor is deliberately low so anything can depend on this.
// Sources stay inside what macOS 10.15 and iOS 13 allow.
let package = Package(
    name: "YAMLCamel",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6)],
    products: [
        .library(name: "YAMLCamel", targets: ["YAMLCamel"]),
        .library(name: "YAMLCamelGzip", targets: ["YAMLCamelGzip"]),
        .library(name: "YAMLCamelHTTP", targets: ["YAMLCamelHTTP"]),
    ],
    targets: [
        .target(name: "YAMLCamel", swiftSettings: [.swiftLanguageMode(.v5)]),

        // zlib is present on macOS and on Linux, so linking the system copy keeps this portable
        // and keeps a deflate implementation out of the repository.
        .systemLibrary(name: "CZlib",
                       path: "Sources/CZlib",
                       providers: [.apt(["zlib1g-dev"]), .brew(["zlib"])]),

        .target(name: "YAMLCamelGzip",
                dependencies: ["YAMLCamel", "CZlib"],
                swiftSettings: [.swiftLanguageMode(.v5)]),

        .target(name: "YAMLCamelHTTP",
                dependencies: ["YAMLCamel", "YAMLCamelGzip"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "YAMLCamelTests",
                    dependencies: ["YAMLCamel"],
                    resources: [.copy("Corpus"), .copy("YAMLTestSuite")],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "YAMLCamelGzipTests",
                    dependencies: ["YAMLCamelGzip"],
                    resources: [.copy("Corpus")],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "YAMLCamelHTTPTests",
                    dependencies: ["YAMLCamelHTTP"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

