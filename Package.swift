// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Blackbox",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
        .package(url: "https://github.com/MimicScribe/dtln-aec-coreml.git", from: "0.4.0-beta"),
    ],
    targets: [
        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AVFAudio"),
            ]
        ),
        .executableTarget(
            name: "BlackboxWatchdog",
            path: "Sources/Watchdog",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
            ]
        ),
        .executableTarget(
            name: "Blackbox",
            dependencies: [
                "ObjCExceptionCatcher",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "DTLNAecCoreML", package: "dtln-aec-coreml"),
                .product(name: "DTLNAec256", package: "dtln-aec-coreml"),
            ],
            path: "Sources",
            exclude: ["ObjCExceptionCatcher", "Watchdog"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
                .treatAllWarnings(as: .error),
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        .testTarget(
            name: "BlackboxTests",
            dependencies: ["Blackbox"],
            path: "Tests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
            ]
        ),
    ]
)
