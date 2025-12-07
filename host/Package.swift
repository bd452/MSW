// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WinRunHost",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "WinRunShared", targets: ["WinRunShared"]),
        .library(name: "WinRunXPCInterfaces", targets: ["WinRunXPC"]),
        .library(name: "WinRunVirtualMachine", targets: ["WinRunVirtualMachine"]),
        .library(name: "WinRunSpiceBridge", targets: ["WinRunSpiceBridge"]),
        .executable(name: "winrund", targets: ["WinRunDaemon"]),
        .executable(name: "WinRunApp", targets: ["WinRunApp"]),
        .executable(name: "winrun", targets: ["WinRunCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "WinRunShared",
            dependencies: [],
            path: "Sources/WinRunShared"
        ),
        .target(
            name: "WinRunXPC",
            dependencies: ["WinRunShared"],
            path: "Sources/WinRunXPC"
        ),
        .target(
            name: "WinRunSpiceBridge",
            dependencies: ["WinRunShared"],
            path: "Sources/WinRunSpiceBridge"
        ),
        .target(
            name: "WinRunVirtualMachine",
            dependencies: [
                "WinRunShared",
                "WinRunSpiceBridge"
            ],
            path: "Sources/WinRunVirtualMachine"
        ),
        .executableTarget(
            name: "WinRunDaemon",
            dependencies: [
                "WinRunShared",
                "WinRunXPC",
                "WinRunVirtualMachine"
            ],
            path: "Sources/WinRunDaemon"
        ),
        .executableTarget(
            name: "WinRunApp",
            dependencies: [
                "WinRunShared",
                "WinRunXPC",
                "WinRunSpiceBridge"
            ],
            path: "Sources/WinRunApp",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "WinRunCLI",
            dependencies: [
                "WinRunShared",
                "WinRunXPC",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/WinRunCLI"
        ),
        .testTarget(
            name: "WinRunSharedTests",
            dependencies: ["WinRunShared"],
            path: "Tests/WinRunSharedTests"
        )
    ]
)
