// swift-tools-version: 5.9
import PackageDescription

#if os(macOS)
let spiceBridgeHelperTargets: [Target] = [
    .systemLibrary(
        name: "CSpiceGlib",
        pkgConfig: "spice-client-glib-2.0",
        providers: [
            .brew(["spice-gtk"]),
            .apt(["spice-client-glib-2.0"])
        ]
    ),
    .target(
        name: "CSpiceBridge",
        dependencies: ["CSpiceGlib"],
        path: "Sources/CSpiceBridge",
        publicHeadersPath: "include",
        cSettings: [
            .headerSearchPath("../CSpiceGlib")
        ]
    )
]
let spiceBridgeDependencies: [Target.Dependency] = ["WinRunShared", "CSpiceBridge"]
#else
let spiceBridgeHelperTargets: [Target] = []
let spiceBridgeDependencies: [Target.Dependency] = ["WinRunShared"]
#endif

var targets: [Target] = [
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
        dependencies: spiceBridgeDependencies,
        path: "Sources/WinRunSpiceBridge"
    ),
    .target(
        name: "WinRunSetup",
        dependencies: ["WinRunShared", "WinRunSpiceBridge"],
        path: "Sources/WinRunSetup"
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
            "WinRunSpiceBridge",
            "WinRunSetup"
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
    ),
    .testTarget(
        name: "WinRunSpiceBridgeTests",
        dependencies: ["WinRunSpiceBridge", "WinRunShared"],
        path: "Tests/WinRunSpiceBridgeTests"
    ),
    .testTarget(
        name: "WinRunVirtualMachineTests",
        dependencies: ["WinRunVirtualMachine", "WinRunShared"],
        path: "Tests/WinRunVirtualMachineTests"
    ),
    .testTarget(
        name: "WinRunXPCTests",
        dependencies: ["WinRunXPC", "WinRunShared"],
        path: "Tests/WinRunXPCTests"
    ),
    .testTarget(
        name: "WinRunSetupTests",
        dependencies: ["WinRunSetup", "WinRunShared"],
        path: "Tests/WinRunSetupTests"
    )
]

targets.append(contentsOf: spiceBridgeHelperTargets)

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
        .library(name: "WinRunSetup", targets: ["WinRunSetup"]),
        .executable(name: "winrund", targets: ["WinRunDaemon"]),
        .executable(name: "WinRunApp", targets: ["WinRunApp"]),
        .executable(name: "winrun", targets: ["WinRunCLI"])
    ],
    dependencies: [
        // swift-argument-parser 1.7.0 requires the experimental `AccessLevelOnImport` feature
        // (`internal import ...`) with older Swift toolchains used in CI. Cap to the last
        // compatible minor series.
        .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMinor(from: "1.6.0"))
    ],
    targets: targets
)
