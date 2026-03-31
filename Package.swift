// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vortex",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VortexCLI", targets: ["VortexCLI"]),
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
        .testTarget(
            name: "VortexCoreTests",
            dependencies: ["VortexCore"],
            path: "Tests/VortexCoreTests"
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
            dependencies: ["VortexCore", "VortexHV", "VortexAudio"],
            path: "Sources/VortexDevices"
        ),
        .testTarget(
            name: "VortexDevicesTests",
            dependencies: ["VortexDevices"],
            path: "Tests/VortexDevicesTests"
        ),

        // MARK: - Boot / firmware
        .target(
            name: "VortexBoot",
            dependencies: ["VortexCore", "VortexHV"],
            path: "Sources/VortexBoot",
            resources: [
                .copy("UEFI/Resources"),
            ]
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
            dependencies: ["VortexCore", "VortexAudio", "VortexPersistence"],
            path: "Sources/VortexVZ",
            linkerSettings: [
                .linkedFramework("Virtualization"),
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

        // MARK: - CLI
        .executableTarget(
            name: "VortexCLI",
            dependencies: [
                "VortexCore",
                "VortexHV",
                "VortexDevices",
                "VortexAudio",
                "VortexBoot",
                "VortexPersistence",
                "VortexVZ",
                "VortexInterception",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/VortexCLI"
        ),
    ]
)
