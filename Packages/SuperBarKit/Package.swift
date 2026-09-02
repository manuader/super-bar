// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SuperBarKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SuperBarKit", targets: ["SuperBarKit"]),
    ],
    targets: [
        .target(
            name: "SBObjC",
            path: "Sources/SBObjC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SuperBarKit",
            dependencies: ["SBObjC"],
            path: "Sources/SuperBarKit",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=targeted"]),
            ]
        ),
        .testTarget(
            name: "SuperBarKitTests",
            dependencies: ["SuperBarKit"],
            path: "Tests/SuperBarKitTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
