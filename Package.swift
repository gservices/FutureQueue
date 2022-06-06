// swift-tools-version:5.6
import PackageDescription

let package = Package(
    name: "FutureQueue",
    platforms: [.iOS(.v9)],
    products: [
        .library(
            name: "FutureQueue",
            targets: ["FutureQueue"]
        ),
    ],
    
    dependencies: [],
    
    targets: [
        .target(
            name: "FutureQueue",
            dependencies: []),
        .testTarget(
            name: "FutureQueueTests",
            dependencies: ["FutureQueue"]),
    ]
)
