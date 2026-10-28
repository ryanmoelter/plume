// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ScrcpyControl",
    platforms: [.macOS("26.2")],
    products: [
        .library(name: "ScrcpyControl", targets: ["ScrcpyControl"]),
        .executable(name: "ScrcpyProbe", targets: ["ScrcpyProbe"]),
    ],
    targets: [
        .target(name: "ScrcpyControl"),
        .executableTarget(
            name: "ScrcpyProbe",
            dependencies: ["ScrcpyControl"]
        ),
        .testTarget(
            name: "ScrcpyControlTests",
            dependencies: ["ScrcpyControl"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
