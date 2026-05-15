// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vortex",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VortexCLI", targets: ["VortexCLI"]),
        .executable(name: "VortexGUI", targets: ["VortexGUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // MARK: - Core (pure Swift, no framework deps)
        .target(
            name: "VortexCore",
            path: "Sources/VortexCore"
        ),
        .target(
            name: "VortexNetworking",
            dependencies: ["VortexCore"],
            path: "Sources/VortexNetworking",
            linkerSettings: [
                .linkedFramework("vmnet"),
            ]
        ),
        .testTarget(
            name: "VortexCoreTests",
            dependencies: ["VortexCore"],
            path: "Tests/VortexCoreTests",
            swiftSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),

        // MARK: - Hypervisor VMM
        .target(
            name: "VortexHV",
            dependencies: ["VortexCore"],
            path: "Sources/VortexHV",
            linkerSettings: [
                .linkedFramework("Hypervisor"),
            ]
        ),
        .testTarget(
            name: "VortexHVTests",
            dependencies: ["VortexHV"],
            path: "Tests/VortexHVTests",
            swiftSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),

        // MARK: - Audio routing engine
        .target(
            name: "VortexAudio",
            dependencies: ["VortexCore"],
            path: "Sources/VortexAudio",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .testTarget(
            name: "VortexAudioTests",
            dependencies: ["VortexAudio"],
            path: "Tests/VortexAudioTests",
            swiftSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),

        // MARK: - Device emulation
        .target(
            name: "VortexDevices",
            dependencies: ["VortexCore", "VortexHV", "VortexAudio", "VortexNetworking"],
            path: "Sources/VortexDevices",
            linkerSettings: [
                .linkedFramework("vmnet"),
            ]
        ),
        .testTarget(
            name: "VortexDevicesTests",
            dependencies: ["VortexDevices"],
            path: "Tests/VortexDevicesTests",
            swiftSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),

        // MARK: - Boot / firmware
        .target(
            name: "VortexBoot",
            dependencies: ["VortexCore", "VortexHV"],
            path: "Sources/VortexBoot"
        ),

        // MARK: - Persistence
        .target(
            name: "VortexPersistence",
            dependencies: ["VortexCore"],
            path: "Sources/VortexPersistence"
        ),
        .testTarget(
            name: "VortexPersistenceTests",
            dependencies: ["VortexPersistence"],
            path: "Tests/VortexPersistenceTests",
            swiftSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),

        // MARK: - Virtualization.framework VM manager + vsock audio bridge
        .target(
            name: "VortexVZ",
            dependencies: ["VortexCore", "VortexAudio", "VortexPersistence", "VortexNetworking"],
            path: "Sources/VortexVZ",
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("vmnet"),
            ]
        ),
        .testTarget(
            name: "VortexVZTests",
            dependencies: ["VortexVZ"],
            path: "Tests/VortexVZTests",
            swiftSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),

        // MARK: - Native Linux backend
        .target(
            name: "VortexLinux",
            dependencies: ["VortexCore", "VortexHV", "VortexDevices", "VortexAudio"],
            path: "Sources/VortexLinux"
        ),

        // MARK: - VM owner service and local control plane
        .target(
            name: "VortexService",
            dependencies: ["VortexCore", "VortexAudio", "VortexPersistence", "VortexVZ", "VortexHV", "VortexLinux", "VortexNetworking"],
            path: "Sources/VortexService",
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),

        // MARK: - CFishHook (C library for Mach-O symbol rebinding)
        .target(
            name: "CFishHook",
            path: "Sources/CFishHook",
            publicHeadersPath: "include"
        ),

        // MARK: - Track A: CoreAudio interception experiment
        .target(
            name: "VortexInterception",
            dependencies: ["VortexCore", "CFishHook"],
            path: "Sources/VortexInterception",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Virtualization"),
            ]
        ),
        .testTarget(
            name: "VortexInterceptionTests",
            dependencies: ["VortexInterception"],
            path: "Tests/VortexInterceptionTests",
            swiftSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),

        // MARK: - GUI (minimal VM display app)
        .executableTarget(
            name: "VortexGUI",
            dependencies: [
                "VortexCore",
                "VortexAudio",
                "VortexLinux",
                "VortexPersistence",
                "VortexService",
                "VortexVZ",
            ],
            path: "Sources/VortexGUI",
            exclude: ["Resources"],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),

        // MARK: - CLI
        .executableTarget(
            name: "VortexCLI",
            dependencies: [
                "VortexCore",
                "VortexHV",
                "VortexDevices",
                "VortexLinux",
                "VortexAudio",
                "VortexBoot",
                "VortexPersistence",
                "VortexService",
                "VortexVZ",
                "VortexInterception",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/VortexCLI"
        ),
    ]
)
