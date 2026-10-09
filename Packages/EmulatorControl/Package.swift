// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EmulatorControl",
    platforms: [.macOS("26.2")],
    products: [
        .library(name: "EmulatorControl", targets: ["EmulatorControl"]),
        .executable(name: "EmulatorProbe", targets: ["EmulatorProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2", exact: "2.4.3"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport", exact: "2.10.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf", exact: "2.4.1"),
        .package(url: "https://github.com/apple/swift-protobuf", exact: "1.38.1"),
    ],
    targets: [
        .target(
            name: "EmulatorControl",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2TransportServices", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            exclude: ["Generated/GENERATED_FROM.txt"]
        ),
        .executableTarget(
            name: "EmulatorProbe",
            dependencies: ["EmulatorControl"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
